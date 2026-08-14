import CFFVideoDecoder
import XCTest
@testable import TStreamKit

/// Opus was routed to the decoded PCM path from the start, but the decoder was
/// missing from the build, so an Opus stream fell through to video only. These
/// tests pin the whole way through.
final class OpusTests: XCTestCase {
    private let url = URL(string: "http://stream.test/channel/1")!

    override func tearDown() {
        StubURLProtocol.body = Data()
        StubURLProtocol.contentType = nil
        super.tearDown()
    }

    func testADecoderExistsInThisBuild() throws {
        // OpusHead for 48000 Hz stereo, the setup record a container carries.
        var head = Data("OpusHead".utf8)
        head.append(contentsOf: [1, 2])                       // version, channels
        head.append(contentsOf: [0x38, 0x01])                 // pre-skip
        head.append(contentsOf: [0x80, 0xBB, 0x00, 0x00])     // 48000 Hz
        head.append(contentsOf: [0, 0, 0])                    // gain, mapping

        XCTAssertNotNil(TStreamFFAudioDecoder(codec: CFF_AUDIO_OPUS, sampleRate: 48000,
                                              channels: 2, extradata: head),
                        "libavcodec has no Opus decoder in this build")
    }

    func testOpusInWebMPlaysAsPCM() throws {
        let bundle = Bundle.module
        guard let fixture = bundle.url(forResource: "Fixtures/probe-opus", withExtension: "webm") else {
            throw XCTSkip("fixture probe-opus.webm is missing")
        }
        StubURLProtocol.body = try Data(contentsOf: fixture)
        StubURLProtocol.contentType = "video/webm"

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()
        wait(for: [spy.received], timeout: 10)
        Thread.sleep(forTimeInterval: 0.6)
        source.stop()

        XCTAssertEqual(spy.errors, [])
        XCTAssertEqual(spy.videoFormats.first?.codec, .vp8)
        XCTAssertGreaterThan(spy.video.count, 10)

        let format = try XCTUnwrap(spy.audioFormats.first, "audio never started")
        XCTAssertEqual(format.codec, .pcm, "Opus has to arrive decoded")
        XCTAssertEqual(format.sampleRate, 48000, "Opus always decodes at 48 kHz")
        XCTAssertEqual(format.channels, 2)

        let bytes = spy.audio.reduce(0) { $0 + $1.data.count }
        XCTAssertGreaterThan(bytes, 48_000, "far too little audio for a one second clip")
    }

    /// Decoded audio has to keep the sample exact timeline, Opus included.
    func testOpusKeepsASampleExactTimeline() throws {
        let bundle = Bundle.module
        guard let fixture = bundle.url(forResource: "Fixtures/probe-opus", withExtension: "webm") else {
            throw XCTSkip("fixture probe-opus.webm is missing")
        }
        StubURLProtocol.body = try Data(contentsOf: fixture)
        StubURLProtocol.contentType = "video/webm"

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()
        wait(for: [spy.received], timeout: 10)
        Thread.sleep(forTimeInterval: 0.6)
        source.stop()

        let format = try XCTUnwrap(spy.audioFormats.first)
        let bytesPerFrame = 2 * max(format.channels, 1)
        var worst = 0.0
        for (previous, next) in zip(spy.audio, spy.audio.dropFirst()) {
            let samples = Double(previous.data.count / bytesPerFrame)
            let expected = samples * 90_000.0 / Double(format.sampleRate)
            worst = max(worst, abs(Double(Int64(next.pts) - Int64(previous.pts)) - expected))
        }
        XCTAssertLessThanOrEqual(worst, 1.0, "timeline drifts by \(worst) ticks per buffer")
    }
}
