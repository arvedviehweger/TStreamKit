import Foundation

/// Thread-safe store for the fMP4 initialization segment plus a sliding window
/// of media segments, and the renderer for the live HLS playlists that
/// reference them.
///
/// AVPlayer on iOS requires HLS media segments to be fetched over real HTTP, so
/// these are served by a local loopback HTTP server ([[ios-resourceloader-live-limitation]]).
/// The pipeline writes here from its serial queue while the server reads from
/// its connection queues, so all access is locked.
final class HLSStore {
    struct Segment {
        let sequence: Int
        let data: Data
        let duration: Double
    }

    static let playlistName = "index.m3u8"   // master
    static let mediaName = "media.m3u8"      // media playlist
    static let initName = "init.mp4"
    static func segmentName(_ sequence: Int) -> String { "segment\(sequence).m4s" }

    private let lock = NSLock()
    private var _initSegment: Data?
    private var segments: [Segment] = []
    private var nextSequence = 0
    private let windowSize: Int
    private var variantCodecs: String?
    private var variantResolution: String?

    init(windowSize: Int = 8) {
        self.windowSize = windowSize
    }

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var initSegment: Data? { sync { _initSegment } }
    var hasInit: Bool { sync { _initSegment != nil } }
    var hasVariant: Bool { sync { variantCodecs != nil } }
    var segmentCount: Int { sync { segments.count } }

    func isReady(minimumSegments: Int) -> Bool {
        sync { _initSegment != nil && segments.count >= minimumSegments }
    }

    func setInitSegment(_ data: Data) {
        sync { _initSegment = data }
    }

    func setVariant(codecs: String, resolution: String) {
        sync { variantCodecs = codecs; variantResolution = resolution }
    }

    @discardableResult
    func addSegment(_ data: Data, duration: Double) -> Int {
        sync {
            let sequence = nextSequence
            nextSequence += 1
            segments.append(Segment(sequence: sequence, data: data, duration: duration))
            if segments.count > windowSize {
                segments.removeFirst(segments.count - windowSize)
            }
            return sequence
        }
    }

    func segmentData(forSequence sequence: Int) -> Data? {
        sync { segments.first(where: { $0.sequence == sequence })?.data }
    }

    /// Renders the master playlist pointing at the media playlist.
    func masterPlaylist() -> String {
        sync {
            let codecs = variantCodecs ?? "avc1.640028"
            let resolution = variantResolution ?? "1280x720"
            return [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-STREAM-INF:BANDWIDTH=6000000,CODECS=\"\(codecs)\",RESOLUTION=\(resolution)",
                Self.mediaName,
            ].joined(separator: "\n") + "\n"
        }
    }

    /// Renders the current live media playlist (no `#EXT-X-ENDLIST`).
    func mediaPlaylist() -> String {
        sync {
            let target = max(1, Int(segments.map(\.duration).max()?.rounded(.up) ?? 1))
            let firstSequence = segments.first?.sequence ?? 0
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-TARGETDURATION:\(target)",
                "#EXT-X-MEDIA-SEQUENCE:\(firstSequence)",
                "#EXT-X-MAP:URI=\"\(Self.initName)\"",
            ]
            for segment in segments {
                lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
                lines.append(Self.segmentName(segment.sequence))
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
}
