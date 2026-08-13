import XCTest
@testable import TStreamKit

/// Serves a canned body so the source can be driven end to end without a real
/// server. `HTTPMediaSource` takes a `URLSessionConfiguration`, which is how
/// this gets injected.
final class StubURLProtocol: URLProtocol {
    static var body = Data()
    static var contentType: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers = ["Content-Length": "\(Self.body.count)"]
        if let type = Self.contentType { headers["Content-Type"] = type }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }
}

/// Collects what the source hands the player.
final class MediaSourceSpy: MediaSourceDelegate {
    var video: [(codec: VideoCodec, pts: UInt64)] = []
    var audioFormats: [AudioFormat] = []
    var errors: [TStreamError] = []
    let received = XCTestExpectation(description: "source produced output")

    func mediaSource(_ s: MediaSource, didProduceVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        video.append((codec, pts))
        received.fulfill()
    }
    func mediaSource(_ s: MediaSource, didParseAudioFormat format: AudioFormat) {
        audioFormats.append(format)
    }
    func mediaSource(_ s: MediaSource, didProduceAudio unit: AccessUnit) {}
    func mediaSource(_ s: MediaSource, didFail error: TStreamError) {
        errors.append(error)
        received.fulfill()
    }
}

final class HTTPMediaSourceTests: XCTestCase {
    private let url = URL(string: "http://tvheadend.test/stream/channel/1")!

    override func tearDown() {
        StubURLProtocol.body = Data()
        StubURLProtocol.contentType = nil
        super.tearDown()
    }

    /// A `pass` profile stream: the source has to recognise MPEG-TS and route it
    /// through the hand-written demuxer without being told the format.
    func testDetectsTransportStreamAndProducesVideo() {
        let videoPID: UInt16 = 0x0100
        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true,
                            payload: TS.pmt(videoPID: videoPID, audio: [(0x0F, 0x0101, [])]))
        stream += TS.packet(pid: videoPID, payloadUnitStart: true,
                            payload: TS.pes(streamID: 0xE0, pts: 9000, payload: [0x00, 0x00, 0x01, 0x65]))
        // A second PES start flushes the first, which is what emits it.
        stream += TS.packet(pid: videoPID, payloadUnitStart: true, continuityCounter: 1,
                            payload: TS.pes(streamID: 0xE0, pts: 12600, payload: [0x00, 0x00, 0x01, 0x41]))
        StubURLProtocol.body = Data(stream)

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()

        wait(for: [spy.received], timeout: 5)
        source.stop()

        XCTAssertEqual(spy.errors, [])
        XCTAssertEqual(spy.video.first?.codec, .h264)
        XCTAssertEqual(spy.video.first?.pts, 9000)
    }

    /// A `webtv-*-matroska` profile. Until libavformat is wired up this must
    /// report a clear reason rather than leaving the player on a black screen,
    /// which is what happened before detection existed.
    func testMatroskaReportsUnsupportedRatherThanStayingSilent() {
        var body: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
        body += [UInt8](repeating: 0x00, count: 64)
        StubURLProtocol.body = Data(body)
        StubURLProtocol.contentType = "video/x-matroska"

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()

        wait(for: [spy.received], timeout: 5)
        source.stop()

        XCTAssertEqual(spy.video.count, 0)
        guard case .unsupportedCodec(let message)? = spy.errors.first else {
            return XCTFail("expected an unsupportedCodec error, got \(spy.errors)")
        }
        XCTAssertTrue(message.contains("Matroska"), "message should name the container: \(message)")
    }

    /// Bytes that are no container we know must fail rather than buffer forever.
    func testUnknownContainerFailsAfterProbeLimit() {
        StubURLProtocol.body = Data([UInt8](repeating: 0x5A, count: ContainerFormat.probeLimit + 16))

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()

        wait(for: [spy.received], timeout: 5)
        source.stop()

        guard case .demux? = spy.errors.first else {
            return XCTFail("expected a demux error, got \(spy.errors)")
        }
    }
}
