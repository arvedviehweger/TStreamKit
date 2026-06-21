import AVFoundation
import Foundation

/// Plays a raw HTTP MPEG-TS stream (e.g. from Tvheadend) through `AVPlayer`.
///
/// Internally the stream is demuxed and remuxed into fragmented MP4, exposed as
/// a live HLS playlist by a tiny loopback HTTP server (127.0.0.1), because iOS
/// AVPlayer requires HLS media segments to be fetched over real HTTP.
///
/// ```swift
/// let player = try TStreamPlayer(url: URL(string: "http://tvheadend:9981/stream/channel/1")!)
/// player.play()
/// ```
public final class TStreamPlayer {
    /// The underlying AVPlayer — attach it to an `AVPlayerLayer` or
    /// `AVPlayerViewController` to render video.
    public let player: AVPlayer

    /// Reports failures on the main thread.
    public var onError: ((TStreamError) -> Void)?

    /// Called on the main thread once playback is ready to begin.
    public var onReadyToPlay: (() -> Void)?

    private let pipeline: TStreamPipeline
    private let server: HLSLocalServer
    private var statusObservation: NSKeyValueObservation?
    private var diagnosticsTimer: Timer?
    private var didStartPlayback = false
    private var shouldPlay = false
    private var stopped = false

    /// Creates a player for the given HTTP MPEG-TS URL.
    /// - Throws: `TStreamError.invalidURL` for a non-HTTP URL, or a transport
    ///   error if the local server cannot start.
    public init(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TStreamError.invalidURL(url.absoluteString)
        }
        self.pipeline = TStreamPipeline(httpURL: url)
        self.player = AVPlayer()

        do {
            self.server = try HLSLocalServer(store: pipeline.store)
        } catch {
            throw TStreamError.transport("could not start local server: \(error.localizedDescription)")
        }

        pipeline.onError = { [weak self] error in
            DispatchQueue.main.async { self?.onError?(error) }
        }
        pipeline.onReady = { [weak self] in
            DispatchQueue.main.async { self?.attachPlayerItem() }
        }

        server.start()
        pipeline.start()
    }

    /// Non-throwing convenience initializer; returns `nil` for an invalid URL.
    public convenience init?(safeURL url: URL) {
        try? self.init(url: url)
    }

    /// Builds the AVPlayer item once the pipeline has buffered enough, pointing
    /// it at the local HLS server.
    private func attachPlayerItem() {
        guard !didStartPlayback, !stopped else { return }
        didStartPlayback = true

        let asset = AVURLAsset(url: server.playlistURL)
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            TStreamDiagnostics.log("player: item.status -> \(item.status.rawValue)")
            switch item.status {
            case .readyToPlay:
                DispatchQueue.main.async { self.onReadyToPlay?() }
            case .failed:
                let message = item.error?.localizedDescription ?? "playback failed"
                DispatchQueue.main.async { self.onError?(.player(message)) }
            default:
                break
            }
        }
        player.replaceCurrentItem(with: item)
        startDiagnosticsTimerIfEnabled(item: item)
        if shouldPlay { player.play() }
    }

    public func play() {
        shouldPlay = true
        player.play()
    }

    public func pause() {
        shouldPlay = false
        player.pause()
    }

    /// Stops playback and tears down the server and pipeline.
    public func stop() {
        stopped = true
        player.pause()
        statusObservation?.invalidate()
        statusObservation = nil
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        player.replaceCurrentItem(with: nil)
        pipeline.stop()
        server.stop()
    }

    deinit {
        statusObservation?.invalidate()
        diagnosticsTimer?.invalidate()
        pipeline.stop()
        server.stop()
    }

    private func startDiagnosticsTimerIfEnabled(item: AVPlayerItem) {
        guard TStreamDiagnostics.isEnabled else { return }
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak item] _ in
            guard let self, let item else { return }
            let ranges = item.loadedTimeRanges.map { v -> String in
                let r = v.timeRangeValue
                return String(format: "%.1f+%.1f", CMTimeGetSeconds(r.start), CMTimeGetSeconds(r.duration))
            }
            TStreamDiagnostics.log("player: status=\(item.status.rawValue) tcs=\(self.player.timeControlStatus.rawValue) keepUp=\(item.isPlaybackLikelyToKeepUp) loaded=\(ranges)")
        }
    }
}
