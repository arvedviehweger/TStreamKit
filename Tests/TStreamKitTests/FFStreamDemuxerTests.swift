import CoreVideo
import XCTest
@testable import TStreamKit

/// Drives real container files through the whole source: HTTP transport,
/// container detection, libavformat demuxing. These are the containers a
/// transcoding server serves, so a regression here means a streaming profile
/// stops playing.
final class FFStreamDemuxerTests: XCTestCase {
    private let url = URL(string: "http://stream.test/channel/1")!

    override func tearDown() {
        StubURLProtocol.body = Data()
        StubURLProtocol.contentType = nil
        super.tearDown()
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "Fixtures/\(name)", withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext) else {
            throw XCTSkip("fixture \(name).\(ext) is missing")
        }
        return try Data(contentsOf: url)
    }

    /// Runs a fixture through the source and waits for it to settle.
    private func play(_ data: Data, contentType: String?) -> MediaSourceSpy {
        StubURLProtocol.body = data
        StubURLProtocol.contentType = contentType

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()

        wait(for: [spy.received], timeout: 10)
        // The demux thread keeps emitting after the first packet; give it a beat
        // to drain the one-second clip before inspecting the totals.
        Thread.sleep(forTimeInterval: 0.5)
        source.stop()
        return spy
    }

    func testPlaysMatroskaWithH264AndAAC() throws {
        let spy = play(try fixture("probe", "mkv"), contentType: "video/x-matroska")

        XCTAssertEqual(spy.errors, [])
        XCTAssertEqual(spy.videoFormats.first?.codec, .h264)
        // H.264 in Matroska is length-prefixed, so the decoder cannot start
        // without the avcC record from the container.
        XCTAssertGreaterThan(spy.videoFormats.first?.extradata?.count ?? 0, 0)
        XCTAssertGreaterThan(spy.video.count, 10, "a one-second 25fps clip should yield ~25 frames")
        XCTAssertEqual(spy.audioFormats.first?.codec, .aac)
        XCTAssertEqual(spy.audioFormats.first?.sampleRate, 44100)
    }

    func testPlaysFragmentedMP4() throws {
        let spy = play(try fixture("probe", "mp4"), contentType: "video/mp4")

        XCTAssertEqual(spy.errors, [])
        XCTAssertEqual(spy.videoFormats.first?.codec, .h264)
        XCTAssertGreaterThan(spy.videoFormats.first?.extradata?.count ?? 0, 0)
        XCTAssertGreaterThan(spy.video.count, 10)
        XCTAssertEqual(spy.audioFormats.first?.codec, .aac)
    }

    /// VP8 video is reported; Vorbis audio is not, because it needs decoding to
    /// PCM first. Video must still play rather than the whole stream failing.
    func testPlaysWebMVideoAndSkipsVorbisAudio() throws {
        let spy = play(try fixture("probe", "webm"), contentType: "video/webm")

        XCTAssertEqual(spy.errors, [])
        XCTAssertEqual(spy.videoFormats.first?.codec, .vp8)
        XCTAssertGreaterThan(spy.video.count, 10)
        XCTAssertEqual(spy.audioFormats.count, 0, "Vorbis has no PCM path yet")
    }

    /// The packets have to survive the whole way into pixels. This is the part
    /// that breaks without extradata: in Matroska the NAL units are length
    /// prefixed and the parameter sets live in the avcC record, so a decoder
    /// built the MPEG-TS way produces nothing at all.
    func testMatroskaVideoDecodesToFrames() throws {
        let spy = play(try fixture("probe", "mkv"), contentType: "video/x-matroska")
        guard let format = spy.videoFormats.first else {
            return XCTFail("no video format was reported")
        }
        guard let decoder = TStreamFFVideoDecoder(codec: format.codec, packetized: true, extradata: format.extradata) else {
            return XCTFail("could not create the decoder")
        }

        var frames: [TStreamFFVideoDecoder.DecodedFrame] = []
        for (index, packet) in spy.videoData.enumerated() {
            let pts = Int64(index) * 3600        // 25 fps at 90 kHz
            frames += decoder.decode(packet, pts: pts, dts: pts)
        }

        XCTAssertGreaterThan(frames.count, 10, "the container's video did not decode")
        let first = try XCTUnwrap(frames.first).pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(first), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(first), 96)
    }

    /// Same check for VP8, which only ever reaches us through a container.
    func testWebMVideoDecodesToFrames() throws {
        let spy = play(try fixture("probe", "webm"), contentType: "video/webm")
        guard let format = spy.videoFormats.first else {
            return XCTFail("no video format was reported")
        }
        guard let decoder = TStreamFFVideoDecoder(codec: format.codec, packetized: true, extradata: format.extradata) else {
            return XCTFail("could not create the VP8 decoder")
        }

        var frames: [TStreamFFVideoDecoder.DecodedFrame] = []
        for (index, packet) in spy.videoData.enumerated() {
            let pts = Int64(index) * 3600
            frames += decoder.decode(packet, pts: pts, dts: pts)
        }

        XCTAssertGreaterThan(frames.count, 10, "VP8 did not decode")
        let first = try XCTUnwrap(frames.first).pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(first), 128)
    }

    /// Timestamps must arrive rescaled to the 90 kHz clock the player runs on,
    /// not in the container's own time base.
    func testTimestampsAreRescaledTo90kHz() throws {
        let spy = play(try fixture("probe", "mkv"), contentType: "video/x-matroska")

        let stamps = spy.video.map(\.pts).sorted()
        guard stamps.count > 10 else { return XCTFail("not enough frames: \(stamps.count)") }
        // One second of content at 90 kHz spans about 90000 ticks. Allow slack
        // for however many frames actually made it through.
        let span = stamps.last! - stamps.first!
        XCTAssertGreaterThan(span, 20_000, "span \(span) is too small to be 90 kHz")
        XCTAssertLessThan(span, 120_000, "span \(span) is too large to be 90 kHz")
    }
}
