import AudioToolbox
import CoreMedia
import XCTest
@testable import TStreamKit

final class CoreAudioSupportTests: XCTestCase {

    private func aac(_ config: [UInt8], rate: Int = 48000, channels: Int = 2) -> AudioFormat {
        AudioFormat(codec: .aac, sampleRate: rate, channels: channels,
                    samplesPerFrame: 1024, decoderConfig: Data(config))
    }

    func testLowComplexityIsAccepted() {
        XCTAssertTrue(CoreAudioSupport.canDecode(aac([0x11, 0x90])))
        XCTAssertTrue(CoreAudioSupport.canDecode(aac([0x12, 0x10], rate: 44100)))
    }

    func testHighEfficiencyIsAccepted() {
        XCTAssertTrue(CoreAudioSupport.canDecode(aac([0x2B, 0x11, 0x88])))
    }

    /// The config a transcoding server actually sent us. Core Audio has no
    /// decoder for AAC Main, whatever we describe it as, so this has to come
    /// back false or the stream plays silently.
    func testMainIsRefusedSoItCanBeDecodedElsewhere() {
        XCTAssertFalse(CoreAudioSupport.canDecode(aac([0x09, 0x90])))
        XCTAssertFalse(CoreAudioSupport.canDecode(aac([0x09, 0x90, 0x56, 0xE5, 0x00])))
    }

    /// Nothing else may be pushed onto the fallback by accident: the codecs the
    /// system handles have to keep going through it.
    func testFormatsThatMustKeepUsingTheSystemDecoder() {
        let pcm = AudioFormat(codec: .pcm, sampleRate: 48000, channels: 2,
                              samplesPerFrame: 1, decoderConfig: Data())
        XCTAssertTrue(CoreAudioSupport.canDecode(pcm))

        let ac3 = AudioFormat(codec: .ac3, sampleRate: 48000, channels: 2,
                              samplesPerFrame: 1536, decoderConfig: Data())
        XCTAssertTrue(CoreAudioSupport.canDecode(ac3))
    }

    /// An AAC-LC description has to carry the config through as a cookie, since
    /// that is what the decoder reads the profile from.
    func testDescriptionCarriesTheCookie() throws {
        let description = try XCTUnwrap(CoreAudioSupport.formatDescription(for: aac([0x11, 0x90])))
        var size = 0
        XCTAssertNotNil(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size))
        XCTAssertGreaterThan(size, 0)

        let asbd = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mFramesPerPacket, 1024)
        XCTAssertEqual(asbd.mSampleRate, 48000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    }

    /// HE-AAC decodes twice as many samples per packet, and the config is the
    /// only place that says so.
    func testHighEfficiencyDescriptionUsesTheDoubledPacketLength() throws {
        let description = try XCTUnwrap(
            CoreAudioSupport.formatDescription(for: aac([0x2B, 0x11, 0x88])))
        let asbd = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC_HE)
        XCTAssertEqual(asbd.mFramesPerPacket, 2048)
    }
}
