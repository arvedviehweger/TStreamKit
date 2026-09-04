import XCTest
@testable import TStreamKit

/// Serves `body` like a recording whose first connection breaks off halfway:
/// the first request delivers `dropAfter` bytes and then times out, and later
/// requests answer the `Range` they ask for — or, with `ignoresRange`, send
/// the whole file again the way a server without range support would.
final class DroppingURLProtocol: URLProtocol {
    static var body = Data()
    static var dropAfter = 0
    static var ignoresRange = false
    static private(set) var ranges: [String?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.ranges.append(range)
        let url = request.url!
        if Self.ranges.count == 1 {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(Self.body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body.prefix(Self.dropAfter))
            // Failing in the same breath would discard the bytes just loaded.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            return
        }
        var start = 0
        if !Self.ignoresRange, let range, range.hasPrefix("bytes="), range.hasSuffix("-"),
           let value = Int(range.dropFirst(6).dropLast()) {
            start = value
        }
        let rest = Self.body.suffix(from: start)
        var headers = ["Content-Length": "\(rest.count)"]
        if start > 0 { headers["Content-Range"] = "bytes \(start)-\(Self.body.count - 1)/\(Self.body.count)" }
        let response = HTTPURLResponse(url: url, statusCode: start > 0 ? 206 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(rest))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { ranges = []; ignoresRange = false }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DroppingURLProtocol.self]
        return config
    }
}

final class HTTPReconnectTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.bytestream")

    override func setUp() {
        DroppingURLProtocol.reset()
        DroppingURLProtocol.body = Data((0..<200_000).map { UInt8($0 % 251) })
        DroppingURLProtocol.dropAfter = 70_000
    }

    private func makeStream() -> HTTPByteStream {
        HTTPByteStream(url: URL(string: "http://tvh.test/dvrfile/abc")!, queue: queue,
                       configuration: DroppingURLProtocol.configuration())
    }

    /// A recording that loses its connection mid-file carries on from the next
    /// byte instead of failing, and the consumer never sees a seam.
    func testBrokenOffRecordingContinuesWhereItStopped() {
        let stream = makeStream()
        var received = Data()
        var errors: [TStreamError] = []
        var resets = 0
        let finished = expectation(description: "finished")
        stream.onData = { received.append($0) }
        stream.onReset = { resets += 1 }
        stream.onError = { errors.append($0) }
        stream.onFinish = { finished.fulfill() }
        stream.start()
        wait(for: [finished], timeout: 5)
        queue.sync {}

        XCTAssertEqual(received, DroppingURLProtocol.body)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(DroppingURLProtocol.ranges, [nil, "bytes=70000-"])
        stream.stop()
    }

    /// Resuming against a server that answers a range with the whole file would
    /// splice the start of the recording in; that has to fail instead.
    func testContinuationRefusesAServerThatIgnoresRange() {
        DroppingURLProtocol.ignoresRange = true
        let stream = makeStream()
        var received = 0
        let failed = expectation(description: "failed")
        stream.onData = { received += $0.count }
        stream.onError = { _ in failed.fulfill() }
        stream.start()
        wait(for: [failed], timeout: 5)
        queue.sync {}

        XCTAssertEqual(received, DroppingURLProtocol.dropAfter)
        stream.stop()
    }

    /// A connection that dies while the consumer has the stream paused is only
    /// picked up again once it asks for more.
    func testReconnectWaitsForResumeWhilePaused() {
        let stream = makeStream()
        var received = Data()
        let finished = expectation(description: "finished")
        stream.onData = { [weak stream] data in
            received.append(data)
            if received.count == DroppingURLProtocol.dropAfter { stream?.pause() }
        }
        stream.onFinish = { finished.fulfill() }
        stream.start()

        Thread.sleep(forTimeInterval: 0.5)
        queue.sync {}
        XCTAssertEqual(DroppingURLProtocol.ranges.count, 1)

        stream.resume()
        wait(for: [finished], timeout: 5)
        queue.sync {}
        XCTAssertEqual(received, DroppingURLProtocol.body)
        stream.stop()
    }
}
