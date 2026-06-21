import XCTest
import AVFoundation
@testable import TStreamKit

/// End-to-end test of the live feed: a real `AVPlayer` consuming the
/// `tstream://` asset, fed by the resource loader from a local streaming server.
/// Reproduces (and gates the fix for) the "black screen / Loading forever" bug.
final class LivePlaybackTests: XCTestCase {
    private func sampleTS() throws -> Data {
        // Prefer a longer sample so the live playlist has enough segments to
        // start; fall back to the short canonical sample.
        let env = ProcessInfo.processInfo.environment["TSREAM_TS_INPUT"]
        let candidates = [env, "/tmp/tsserve/stream.ts", "/tmp/tstream_sample.ts"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Provide a sample TS (see OfflineMuxHarness/testDumpHLS).")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func testLivePlaybackReachesReadyToPlay() throws {
        let ts = try sampleTS()
        TStreamDiagnostics.isEnabled = true
        TStreamDiagnostics.mirrorsToStandardOut = true

        let server = try LocalTSServer(serving: ts)
        server.start()
        try runPlayback(server: server, timeout: 25)
    }

    /// Reproduces the real Tvheadend/ffmpeg case: bytes arrive at ~1x realtime
    /// rather than as a fast bulk download.
    func testLivePlaybackRealtimePacing() throws {
        let ts = try sampleTS()
        TStreamDiagnostics.isEnabled = true
        TStreamDiagnostics.mirrorsToStandardOut = true

        // ~4 Mbit/s source → ~500 KB/s. 32 KB every 64 ms ≈ realtime.
        let server = try LocalTSServer(serving: ts, chunkSize: 32_768, chunkDelay: 0.064)
        server.start()
        try runPlayback(server: server, timeout: 30)
    }

    private func runPlayback(server: LocalTSServer, timeout: TimeInterval) throws {
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0, "server did not start")

        let url = URL(string: "http://127.0.0.1:\(server.port)/stream.ts")!
        let player = try TStreamPlayer(url: url)

        let ready = expectation(description: "ready to play")
        var failure: TStreamError?
        player.onReadyToPlay = { print("LIVE: onReadyToPlay"); ready.fulfill() }
        player.onError = { error in
            print("LIVE: onError \(error)")
            failure = error
            ready.fulfill()
        }
        player.play()

        wait(for: [ready], timeout: timeout)
        XCTAssertNil(failure, "playback failed: \(String(describing: failure))")

        // Confirm the clock actually advances (real decode + render path).
        let progressed = expectation(description: "playback progressed")
        let timeObserver = player.player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main) { time in
                if CMTimeGetSeconds(time) > 0.3 { progressed.fulfill() }
            }
        wait(for: [progressed], timeout: 15)
        player.player.removeTimeObserver(timeObserver)
        print("LIVE: playback advanced to \(CMTimeGetSeconds(player.player.currentTime()))s")
    }
}
