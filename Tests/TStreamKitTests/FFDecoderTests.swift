import XCTest
import CFFVideoDecoder

/// Validates that the libavcodec shim decodes the problematic broadcast stream
/// (interlaced, non-IDR, open-GOP) that VideoToolbox can't — run with a raw
/// .h264 elementary stream:
///   TSREAM_H264=/tmp/rtl.h264 swift test --filter FFDecoderTests
final class FFDecoderTests: XCTestCase {
    /// Confirms the MPEG-2 video decoder + parser are present in the linked
    /// libavcodec. Both are enabled in build-ffmpeg.sh and wired as
    /// CFF_CODEC_MPEG2; if the prebuilt Frameworks/*.xcframework predate that,
    /// this skips with a rebuild hint rather than failing the suite.
    func testMPEG2DecoderIsAvailable() throws {
        guard let dec = cff_create(CFF_CODEC_MPEG2) else {
            throw XCTSkip("MPEG-2 decoder/parser not in the linked libavcodec — rebuild with `scripts/build-ffmpeg.sh all`.")
        }
        cff_destroy(dec)
    }

    func testDecodesBroadcastH264() throws {
        guard let path = ProcessInfo.processInfo.environment["TSREAM_H264"] else {
            throw XCTSkip("Set TSREAM_H264 to a raw H.264 elementary stream.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        guard let dec = cff_create(CFF_CODEC_H264) else {
            return XCTFail("cff_create failed")
        }
        defer { cff_destroy(dec) }

        var frames = 0
        var width = 0, height = 0
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            let total = data.count
            var offset = 0
            let chunk = 4096
            while offset < total {
                let n = min(chunk, total - offset)
                _ = cff_feed(dec, base + offset, Int32(n), Int64(offset), Int64(offset))
                offset += n
                var frame = CFFFrame()
                while cff_receive(dec, &frame) == 1 {
                    frames += 1
                    width = Int(frame.width); height = Int(frame.height)
                }
            }
        }
        var s = CFFStats()
        cff_read_stats(dec, &s)
        let n = Double(max(s.frames, 1))
        print(String(format: "FFDEC: decoded \(frames) frames at \(width)x\(height) — threads=%d type=%d, decode %.3fms/f, filter %.3fms/f",
                     s.thread_count, s.thread_type, Double(s.decode_us)/n/1000, Double(s.filter_us)/n/1000))
        XCTAssertGreaterThan(frames, 100, "expected the stream to decode to many frames")
        XCTAssertEqual(width, 720)
        XCTAssertEqual(height, 576)
    }
}
