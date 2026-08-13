import AudioToolbox
import CoreMedia
import XCTest
@testable import TStreamKit

/// Checking that a format description gets created proves nothing here: Core
/// Audio accepts a malformed AAC magic cookie at that point and only rejects it
/// when a decoder is opened. These tests open one, which is what the audio
/// renderer does out of sight.
final class ElementaryStreamTests: XCTestCase {

    /// AAC-LC, 48000 Hz, stereo. What a container stores as codec private data.
    private let audioSpecificConfig = Data([0x11, 0x90])

    /// Opens an AAC decoder, hands it the cookie and reports what it said.
    private func decoderResponse(toCookie cookie: [UInt8]) throws -> OSStatus {
        var input = AudioStreamBasicDescription()
        input.mSampleRate = 48000
        input.mChannelsPerFrame = 2
        input.mFormatID = kAudioFormatMPEG4AAC
        input.mFramesPerPacket = 1024

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
        XCTAssertEqual(AudioConverterNew(&input, &output, &converter), noErr)
        let opened = try XCTUnwrap(converter)
        defer { AudioConverterDispose(opened) }

        return AudioConverterSetProperty(opened, kAudioConverterDecompressionMagicCookie,
                                         UInt32(cookie.count), cookie)
    }

    func testDescriptorIsAcceptedByADecoder() throws {
        let cookie = ElementaryStream.descriptor(audioSpecificConfig: audioSpecificConfig)
        XCTAssertFalse(cookie.isEmpty)
        XCTAssertEqual(try decoderResponse(toCookie: cookie), noErr,
                       "the cookie was rejected, so the stream would play silently")
    }

    /// The bare config is what a container hands us, and what used to be passed
    /// straight through. Pinned so the regression cannot come back quietly.
    func testBareAudioSpecificConfigIsRejectedByADecoder() throws {
        XCTAssertNotEqual(try decoderResponse(toCookie: [UInt8](audioSpecificConfig)), noErr)
    }

    /// A bare config sails through description creation, which is exactly why
    /// the fault stayed invisible until playback.
    func testCreatingADescriptionDoesNotValidateTheCookie() {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 48000
        asbd.mChannelsPerFrame = 2
        asbd.mFormatID = kAudioFormatMPEG4AAC
        asbd.mFramesPerPacket = 1024

        var description: CMAudioFormatDescription?
        let created = audioSpecificConfig.withUnsafeBytes { c in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: c.count, magicCookie: c.baseAddress,
                extensions: nil, formatDescriptionOut: &description)
        }
        XCTAssertEqual(created, noErr)
        XCTAssertNotNil(description)
    }

    func testLengthsAgreeWithTheContentTheyCover() throws {
        let descriptor = ElementaryStream.descriptor(audioSpecificConfig: audioSpecificConfig)

        XCTAssertEqual(descriptor.first, 0x03, "expected an elementary stream descriptor")
        XCTAssertEqual(Int(descriptor[1]), descriptor.count - 2, "outer length disagrees")

        let config = try XCTUnwrap(descriptor.firstIndex(of: 0x04))
        XCTAssertEqual(Int(descriptor[config + 1]), descriptor.count - config - 5,
                       "decoder config length disagrees")

        let info = try XCTUnwrap(descriptor.firstIndex(of: 0x05))
        XCTAssertEqual(Int(descriptor[info + 1]), audioSpecificConfig.count)
        XCTAssertEqual(Array(descriptor[(info + 2)...(info + 1 + audioSpecificConfig.count)]),
                       [UInt8](audioSpecificConfig), "config was not carried through")
    }

    /// Nothing to describe, or too much to describe with single byte lengths.
    /// An empty cookie is the safe answer: plain AAC-LC still plays.
    func testUndescribableConfigYieldsNoCookieRatherThanAMalformedOne() {
        XCTAssertTrue(ElementaryStream.descriptor(audioSpecificConfig: Data()).isEmpty)
        XCTAssertTrue(ElementaryStream.descriptor(
            audioSpecificConfig: Data(repeating: 0,
                                      count: ElementaryStream.maximumConfigSize + 1)).isEmpty)
    }

    /// The longest config still has to produce lengths that fit in one byte.
    func testLongestAcceptedConfigStillFitsItsLengthBytes() {
        let descriptor = ElementaryStream.descriptor(
            audioSpecificConfig: Data(repeating: 0, count: ElementaryStream.maximumConfigSize))
        XCTAssertFalse(descriptor.isEmpty)
        XCTAssertLessThan(descriptor.count, 130)
        XCTAssertEqual(Int(descriptor[1]), descriptor.count - 2)
    }
}
