import CFFVideoDecoder
import XCTest
@testable import TStreamKit

/// The fallback for AAC profiles Core Audio turns down is only real if
/// libavcodec in this build carries an AAC decoder. It is left out of the build
/// on purpose for everything else, so this is worth pinning.
final class AACFallbackDecoderTests: XCTestCase {

    func testADecoderOpensForTheProfileTheSystemRefuses() throws {
        // AAC Main, 48000 Hz, stereo: the config a transcoding server sent us.
        let decoder = try XCTUnwrap(
            TStreamFFAudioDecoder(codec: CFF_AUDIO_AAC, sampleRate: 48000, channels: 2,
                                  extradata: Data([0x09, 0x90])),
            "libavcodec has no AAC decoder in this build")
        XCTAssertEqual(decoder.sampleRate, 48000)
        XCTAssertEqual(decoder.channels, 2)
    }

    /// Opening a decoder is not the same as getting audio out of it, so run a
    /// real bitstream through and check PCM arrives.
    func testRealFramesDecodeToPCM() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/probe", withExtension: "adts"),
                                "fixture probe.adts is missing")
        let frames = Self.rawFrames(in: try Data(contentsOf: url))
        XCTAssertGreaterThan(frames.count, 5, "fixture carries too little audio to be a test")

        // 48000 Hz mono AAC-LC, matching how the fixture was encoded.
        let decoder = try XCTUnwrap(
            TStreamFFAudioDecoder(codec: CFF_AUDIO_AAC, sampleRate: 48000, channels: 1,
                                  extradata: Data([0x11, 0x88])))

        var bytes = 0
        for (index, frame) in frames.enumerated() {
            for block in decoder.decode(frame, pts: UInt64(index) * 1024) {
                bytes += block.data.count
            }
        }
        XCTAssertGreaterThan(bytes, 0, "the decoder produced no audio at all")
        // Interleaved 16 bit mono, so two bytes a sample. Allow for the decoder
        // holding back a frame; anything near the input length proves the path.
        let expected = frames.count * 1024 * 2
        XCTAssertGreaterThan(bytes, expected / 2, "far less audio came out than went in")
    }

    /// Splits an ADTS file into the raw frames a container would hand us.
    private static func rawFrames(in data: Data) -> [Data] {
        var frames: [Data] = []
        var i = 0
        while i + 7 <= data.count, data[i] == 0xFF, (data[i + 1] & 0xF0) == 0xF0 {
            let length = (Int(data[i + 3] & 0x03) << 11) | (Int(data[i + 4]) << 3) | (Int(data[i + 5]) >> 5)
            let header = (data[i + 1] & 0x01) == 1 ? 7 : 9
            guard length > header, i + length <= data.count else { break }
            frames.append(data.subdata(in: (i + header)..<(i + length)))
            i += length
        }
        return frames
    }
}
