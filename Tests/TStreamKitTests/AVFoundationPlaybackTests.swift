import XCTest
import AVFoundation
@testable import TStreamKit

/// Verifies that AVFoundation itself (the stack AVPlayer uses) can parse and
/// decode the muxer's fMP4 output from a plain file URL. If this passes but
/// live playback via the resource loader fails, the fault is in the live feed,
/// not the muxer.
final class AVFoundationPlaybackTests: XCTestCase {
    /// Plays the TStream HLS output over real HTTP (env TSREAM_HLS_URL), the path
    /// AVPlayer requires for media segments. Confirms segment format validity
    /// independent of the resource loader.
    func testHTTPHLSPlayback() throws {
        guard let urlString = ProcessInfo.processInfo.environment["TSREAM_HLS_URL"],
              let url = URL(string: urlString) else {
            throw XCTSkip("Set TSREAM_HLS_URL to an http HLS playlist.")
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let exp = expectation(description: "ready or failed")
        let obs = item.observe(\.status, options: [.new, .initial]) { item, _ in
            if item.status == .readyToPlay { print("HTTPHLS: readyToPlay dur=\(CMTimeGetSeconds(item.duration))"); exp.fulfill() }
            if item.status == .failed { print("HTTPHLS: FAILED \(String(describing: item.error))"); exp.fulfill() }
        }
        player.play()
        wait(for: [exp], timeout: 15)
        obs.invalidate()
        if let log = item.errorLog() {
            for e in log.events { print("HTTPHLS: errorLog status=\(e.errorStatusCode) comment=\(e.errorComment ?? "nil") uri=\(e.uri ?? "nil")") }
        }
        XCTAssertEqual(item.status, .readyToPlay, "HTTP HLS failed: \(String(describing: item.error))")
    }

    func testAVFoundationCanDecodeFMP4() throws {
        let path = ProcessInfo.processInfo.environment["TSREAM_FMP4_OUTPUT"] ?? "/tmp/tstream_out.mp4"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Run OfflineMuxHarness first to produce \(path).")
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))

        // Inspect tracks synchronously via the legacy API (fine for a test).
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        print("AVF: videoTracks=\(videoTracks.count) audioTracks=\(audioTracks.count) duration=\(CMTimeGetSeconds(asset.duration))s")
        XCTAssertEqual(videoTracks.count, 1, "AVFoundation did not find the video track")
        XCTAssertEqual(audioTracks.count, 1, "AVFoundation did not find the audio track")

        if let v = videoTracks.first {
            let size = v.naturalSize
            print("AVF: video naturalSize=\(size) nominalFrameRate=\(v.nominalFrameRate)")
            XCTAssertEqual(size.width, 1280, accuracy: 1)
            XCTAssertEqual(size.height, 720, accuracy: 1)
        }

        // Decode an actual frame through AVFoundation's pipeline.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // Content starts at ~1.4s (no edit list), so sample within the media.
        let requestTime = CMTime(seconds: 2.5, preferredTimescale: 600)
        var decoded: CGImage?
        var genError: Error?
        let sem = DispatchSemaphore(value: 0)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestTime)]) { _, image, actual, result, error in
            decoded = image
            genError = error
            print("AVF: image gen result=\(result.rawValue) actual=\(CMTimeGetSeconds(actual))s error=\(String(describing: error))")
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)

        XCTAssertNil(genError, "AVFoundation failed to decode a frame: \(String(describing: genError))")
        XCTAssertNotNil(decoded, "AVFoundation produced no frame")
        if let decoded {
            print("AVF: decoded frame \(decoded.width)x\(decoded.height)")
        }
    }
}
