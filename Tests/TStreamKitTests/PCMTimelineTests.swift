import XCTest
@testable import TStreamKit

/// Decoded PCM is laid down at exactly the time it is given, so its timestamps
/// have to advance by the audio it actually carries. Container timestamps do
/// not: Matroska rounds to milliseconds while a frame lasts a fraction of one,
/// and reusing them leaves a gap or overlap at every buffer edge that is heard
/// as a click at the frame rate.
final class PCMTimelineTests: XCTestCase {
    private let url = URL(string: "http://stream.test/channel/1")!

    override func tearDown() {
        StubURLProtocol.body = Data()
        StubURLProtocol.contentType = nil
        super.tearDown()
    }

    private func play(_ name: String, _ ext: String, contentType: String) throws -> MediaSourceSpy {
        let bundle = Bundle.module
        guard let fixture = bundle.url(forResource: "Fixtures/\(name)", withExtension: ext) else {
            throw XCTSkip("fixture \(name).\(ext) is missing")
        }
        StubURLProtocol.body = try Data(contentsOf: fixture)
        StubURLProtocol.contentType = contentType

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()
        wait(for: [spy.received], timeout: 10)
        Thread.sleep(forTimeInterval: 0.6)
        source.stop()
        return spy
    }

    /// WebM carries Vorbis, which Core Audio cannot take, so this exercises the
    /// same decoded PCM path the refused AAC profiles use.
    func testDecodedAudioAdvancesByTheSamplesItCarries() throws {
        let spy = try play("probe", "webm", contentType: "video/webm")

        let format = try XCTUnwrap(spy.audioFormats.first)
        XCTAssertEqual(format.codec, .pcm, "expected the decoded path")
        let bytesPerFrame = 2 * max(format.channels, 1)
        let rate = Double(format.sampleRate)
        XCTAssertGreaterThan(spy.audio.count, 10, "too little audio to judge a timeline")

        var worst = 0.0
        for (previous, next) in zip(spy.audio, spy.audio.dropFirst()) {
            let samples = Double(previous.data.count / bytesPerFrame)
            let expected = samples * 90_000.0 / rate
            let actual = Double(Int64(next.pts) - Int64(previous.pts))
            worst = max(worst, abs(actual - expected))
        }
        // One tick is the 90 kHz grid itself, which no timeline can avoid.
        XCTAssertLessThanOrEqual(worst, 1.0,
                                 "PCM timestamps drift from the audio by \(worst) ticks per buffer")
    }

    /// Timestamps have to keep climbing. The container hands out repeats, and a
    /// repeat means two buffers land on the same instant.
    func testDecodedAudioNeverRepeatsOrGoesBackwards() throws {
        let spy = try play("probe", "webm", contentType: "video/webm")
        for (previous, next) in zip(spy.audio, spy.audio.dropFirst()) {
            XCTAssertGreaterThan(next.pts, previous.pts,
                                 "two buffers share an instant, or time runs backwards")
        }
    }

    /// Passthrough audio must keep the container's own timing: the renderer
    /// decodes those packets itself and joins them up.
    func testPassthroughAudioKeepsTheContainerTimestamps() throws {
        let spy = try play("probe", "mkv", contentType: "video/x-matroska")
        XCTAssertEqual(spy.audioFormats.first?.codec, .aac, "expected the passthrough path")
        XCTAssertGreaterThan(spy.audio.count, 10)
    }
}
