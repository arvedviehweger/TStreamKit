import AudioToolbox
import XCTest
@testable import TStreamKit

final class AudioSpecificConfigTests: XCTestCase {

    /// AAC-LC, 48000 Hz, stereo: object type 2, rate index 3, channels 2.
    func testPlainLowComplexity() throws {
        let config = try XCTUnwrap(AudioSpecificConfig(parsing: Data([0x11, 0x90])))
        XCTAssertEqual(config.objectType, 2)
        XCTAssertEqual(config.sampleRate, 48000)
        XCTAssertEqual(config.channels, 2)
        XCTAssertEqual(config.coreAudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(config.framesPerPacket, 1024)
    }

    func testLowComplexityAtOtherRates() throws {
        // 44100 Hz stereo, the rate our own fixtures use.
        let cd = try XCTUnwrap(AudioSpecificConfig(parsing: Data([0x12, 0x10])))
        XCTAssertEqual(cd.sampleRate, 44100)
        XCTAssertEqual(cd.channels, 2)

        // 44100 Hz mono.
        let mono = try XCTUnwrap(AudioSpecificConfig(parsing: Data([0x12, 0x08])))
        XCTAssertEqual(mono.sampleRate, 44100)
        XCTAssertEqual(mono.channels, 1)
    }

    /// HE-AAC signals object type 5, a core rate and then the output rate.
    /// Core 24000 Hz doubling to 48000 Hz, stereo.
    func testHighEfficiencyReportsTheOutputRate() throws {
        let config = try XCTUnwrap(AudioSpecificConfig(parsing: Data([0x2B, 0x11, 0x88])))
        XCTAssertEqual(config.objectType, 5)
        XCTAssertEqual(config.sampleRate, 48000, "expected the extension rate, not the core rate")
        XCTAssertEqual(config.channels, 2)
        XCTAssertEqual(config.coreAudioFormatID, kAudioFormatMPEG4AAC_HE)
        XCTAssertEqual(config.framesPerPacket, 2048, "band replication doubles the samples")
    }

    /// An object type of 31 escapes to a six bit value offset by 32.
    func testEscapedObjectType() throws {
        // Object type 39 (ELD) as 31 then 7, rate index 3, channel config 2:
        // 11111 000111 0011 0010.
        let config = try XCTUnwrap(AudioSpecificConfig(parsing: Data([0xF8, 0xE6, 0x40])))
        XCTAssertEqual(config.objectType, 39)
        XCTAssertEqual(config.sampleRate, 48000)
        XCTAssertEqual(config.coreAudioFormatID, kAudioFormatMPEG4AAC_ELD)
    }

    /// A channel configuration of zero defers to a program config element, so
    /// there is no count to take from here.
    func testUnsetChannelConfigurationIsReportedAsZero() throws {
        let config = try XCTUnwrap(AudioSpecificConfig(parsing: Data([0x11, 0x80])))
        XCTAssertEqual(config.channels, 0)
    }

    func testTruncatedOrEmptyConfigIsRejected() {
        XCTAssertNil(AudioSpecificConfig(parsing: Data()))
        XCTAssertNil(AudioSpecificConfig(parsing: Data([0x11])))
    }

    /// Every config we accept has to survive the round trip into a cookie a
    /// decoder will take, which is the whole point of reading it.
    func testEveryAcceptedConfigProducesAWorkingDecoder() throws {
        let configs: [(String, Data)] = [
            ("AAC-LC 48000 stereo", Data([0x11, 0x90])),
            ("AAC-LC 44100 stereo", Data([0x12, 0x10])),
            ("AAC-LC 44100 mono",   Data([0x12, 0x08])),
            ("HE-AAC 48000 stereo", Data([0x2B, 0x11, 0x88])),
        ]
        for (name, data) in configs {
            let config = try XCTUnwrap(AudioSpecificConfig(parsing: data), name)

            var input = AudioStreamBasicDescription()
            input.mSampleRate = Float64(config.sampleRate)
            input.mChannelsPerFrame = UInt32(max(config.channels, 1))
            input.mFormatID = config.coreAudioFormatID
            input.mFramesPerPacket = UInt32(config.framesPerPacket)

            var output = AudioStreamBasicDescription()
            output.mSampleRate = input.mSampleRate
            output.mFormatID = kAudioFormatLinearPCM
            output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            output.mChannelsPerFrame = input.mChannelsPerFrame
            output.mBitsPerChannel = 16
            output.mFramesPerPacket = 1
            output.mBytesPerFrame = 2 * input.mChannelsPerFrame
            output.mBytesPerPacket = output.mBytesPerFrame

            var converter: AudioConverterRef?
            XCTAssertEqual(AudioConverterNew(&input, &output, &converter), noErr, name)
            let opened = try XCTUnwrap(converter, name)
            defer { AudioConverterDispose(opened) }

            let cookie = ElementaryStream.descriptor(audioSpecificConfig: data)
            XCTAssertEqual(AudioConverterSetProperty(opened, kAudioConverterDecompressionMagicCookie,
                                                     UInt32(cookie.count), cookie), noErr,
                           "\(name) would play silently")
        }
    }
}
