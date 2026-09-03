import XCTest
@testable import TStreamKit

/// Serves a canned body so the source can be driven end to end without a real
/// server. `HTTPMediaSource` takes a `URLSessionConfiguration`, which is how
/// this gets injected.
final class StubURLProtocol: URLProtocol {
    static var body = Data()
    static var contentType: String?
    /// How many attempts answer with headers and then drop the connection
    /// without a byte of body — what a server does when it accepts the request
    /// but the stream behind it fails to start.
    static var emptyFailures = 0
    static private(set) var attempts = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attempts += 1
        if Self.emptyFailures > 0 {
            Self.emptyFailures -= 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var headers = ["Content-Length": "\(Self.body.count)"]
        if let type = Self.contentType { headers["Content-Type"] = type }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func resetAttempts() { attempts = 0 }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }
}

/// Collects what the source hands the player.
final class MediaSourceSpy: MediaSourceDelegate {
    var video: [(codec: VideoCodec, pts: UInt64)] = []
    var videoData: [Data] = []
    var videoFormats: [(codec: VideoCodec, extradata: Data?, pixelAspect: PixelAspect?)] = []
    var audioFormats: [AudioFormat] = []
    var audioOnly = false
    var audio: [AccessUnit] = []
    var errors: [TStreamError] = []
    let received = XCTestExpectation(description: "source produced output")

    func mediaSource(_ s: MediaSource, didParseVideoFormat codec: VideoCodec, extradata: Data?,
                     pixelAspect: PixelAspect?) {
        videoFormats.append((codec, extradata, pixelAspect))
    }

    func mediaSource(_ s: MediaSource, didProduceVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        video.append((codec, pts))
        videoData.append(data)
        received.fulfill()
    }
    func mediaSourceDidDetectAudioOnly(_ s: MediaSource) {
        audioOnly = true
    }
    func mediaSource(_ s: MediaSource, didParseAudioFormat format: AudioFormat) {
        audioFormats.append(format)
    }
    func mediaSource(_ s: MediaSource, didProduceAudio unit: AccessUnit) {
        audio.append(unit)
    }
    func mediaSource(_ s: MediaSource, didFail error: TStreamError) {
        errors.append(error)
        received.fulfill()
    }
}

final class HTTPMediaSourceTests: XCTestCase {
    private let url = URL(string: "http://stream.test/channel/1")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.emptyFailures = 0
        StubURLProtocol.resetAttempts()
    }

    override func tearDown() {
        StubURLProtocol.body = Data()
        StubURLProtocol.contentType = nil
        StubURLProtocol.emptyFailures = 0
        super.tearDown()
    }

    /// A live stream that dies before its first byte is worth one more try: a
    /// server still releasing the previous subscription answers and then hangs
    /// up, and the same request a moment later works.
    func testStreamThatStartsWithNoDataIsRetriedOnce() {
        StubURLProtocol.emptyFailures = 1
        StubURLProtocol.body = Data(Self.transportStream())

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        source.start()

        wait(for: [spy.received], timeout: 5)
        source.stop()

        XCTAssertEqual(StubURLProtocol.attempts, 2)
        XCTAssertEqual(spy.errors, [])
        XCTAssertEqual(spy.video.first?.pts, 9000)
    }

    /// Twice is not bad luck. The second refusal is reported instead of being
    /// retried forever, and it says what actually happened.
    func testAServerThatKeepsSendingNothingIsReported() {
        StubURLProtocol.emptyFailures = 5
        StubURLProtocol.body = Data(Self.transportStream())

        let spy = MediaSourceSpy()
        let source = HTTPMediaSource(url: url, configuration: StubURLProtocol.configuration())
        source.delegate = spy
        let failed = expectation(description: "reported the refusal")
        source.onError = { _ in failed.fulfill() }
        source.start()

        wait(for: [failed], timeout: 5)
        source.stop()

        XCTAssertEqual(StubURLProtocol.attempts, 2)
        guard case .transport(let message)? = spy.errors.first else {
            return XCTFail("expected a transport error, got \(spy.errors)")
        }
        XCTAssertTrue(message.contains("sent no stream"), message)
    }

    /// A short MPEG-TS stream carrying one complete H.264 access unit.
    private static func transportStream() -> [UInt8] {
        let videoPID: UInt16 = 0x0100
        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true,
                            payload: TS.pmt(videoPID: videoPID, audio: [(0x0F, 0x0101, [])]))
        stream += TS.packet(pid: videoPID, payloadUnitStart: true,
                            payload: TS.pes(streamID: 0xE0, pts: 9000, payload: [0x00, 0x00, 0x01, 0x65]))
        stream += TS.packet(pid: videoPID, payloadUnitStart: true, continuityCounter: 1,
                            payload: TS.pes(streamID: 0xE0, pts: 12600, payload: [0x00, 0x00, 0x01, 0x41]))
        return stream
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

    /// Content that announces itself as Matroska but is truncated must report a
    /// reason rather than leaving the player on a black screen. Playable
    /// Matroska is covered by FFStreamDemuxerTests.
    func testBrokenMatroskaReportsAnErrorRatherThanStayingSilent() {
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
        guard case .demux? = spy.errors.first else {
            return XCTFail("expected a demux error, got \(spy.errors)")
        }
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


// MARK: - Auth challenges

/// A challenge needs a sender; nothing here is ever called.
private final class NullChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// A Digest-only server answers a Basic header with 401 and closes the
/// connection, which reaches the client as a lost connection rather than as an
/// auth failure. The challenge has to be answered for those servers to work.
final class HTTPByteStreamAuthTests: XCTestCase {
    private let url = URL(string: "http://stream.test/channel/1")!
    private let credential = URLCredential(user: "u", password: "p", persistence: .forSession)

    private func challenge(_ method: String, failures: Int = 0) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "stream.test", port: 9981, protocol: "http",
                                       realm: "tvheadend", authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                          previousFailureCount: failures, failureResponse: nil,
                                          error: nil, sender: NullChallengeSender())
    }

    private func disposition(
        for challenge: URLAuthenticationChallenge, credential: URLCredential?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let stream = HTTPByteStream(url: url, credential: credential,
                                    queue: DispatchQueue(label: "test"))
        let task = URLSession.shared.dataTask(with: url)   // never resumed
        var result: (URLSession.AuthChallengeDisposition, URLCredential?)!
        stream.urlSession(.shared, task: task, didReceive: challenge) { result = ($0, $1) }
        return result
    }

    func testDigestChallengeIsAnsweredWithTheCredential() {
        let (disposition, used) = disposition(for: challenge(NSURLAuthenticationMethodHTTPDigest),
                                              credential: credential)
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(used?.user, "u")
    }

    func testBasicChallengeIsAnsweredToo() {
        let (disposition, _) = disposition(for: challenge(NSURLAuthenticationMethodHTTPBasic),
                                           credential: credential)
        XCTAssertEqual(disposition, .useCredential)
    }

    /// Wrong credentials must not be offered again — that loops. Letting the
    /// 401 through instead turns the hang into a reportable status code.
    func testAFailedAttemptIsNotRepeated() {
        let (disposition, used) = disposition(
            for: challenge(NSURLAuthenticationMethodHTTPDigest, failures: 1),
            credential: credential)
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(used)
    }

    func testWithoutCredentialsTheChallengeIsLeftToTheSystem() {
        let (disposition, _) = disposition(for: challenge(NSURLAuthenticationMethodHTTPDigest),
                                           credential: nil)
        XCTAssertEqual(disposition, .performDefaultHandling)
    }

    /// Server trust is not ours to answer: the system's evaluation stands.
    func testServerTrustIsLeftToTheSystem() {
        let (disposition, _) = disposition(for: challenge(NSURLAuthenticationMethodServerTrust),
                                           credential: credential)
        XCTAssertEqual(disposition, .performDefaultHandling)
    }
}
