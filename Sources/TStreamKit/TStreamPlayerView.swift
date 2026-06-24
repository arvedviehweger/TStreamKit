import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A SwiftUI view that plays an HTTP MPEG-TS stream through the TStream pipeline.
///
/// Internally it decodes the demuxed access units directly through an
/// `AVSampleBufferDisplayLayer` whose VideoToolbox session we control — this
/// recovers from the open-GOP / non-IDR broadcast streams that derail AVPlayer.
///
/// ```swift
/// struct PlayerScreen: View {
///     var body: some View {
///         TStreamPlayerView(url: URL(string: "http://tvheadend:9981/stream/channel/1")!)
///     }
/// }
/// ```
/// An imperative handle for actions that are events rather than state — chiefly
/// seeking. Create one in the host (`@State`), pass it via `.handle(_:)`, and
/// call `seek(toFraction:)` in response to user scrubbing.
public final class TStreamPlayerHandle {
    weak var player: TStreamSampleBufferPlayer?
    public init() {}

    /// Seek to a fraction (0…1) of the recording. GOP-accurate.
    public func seek(toFraction fraction: Double) {
        player?.seek(toFraction: fraction)
    }
}

public struct TStreamPlayerView: View {
    private let url: URL
    private let headers: [String: String]
    private let autoPlay: Bool
    private var isPaused: Bool = false
    private var handle: TStreamPlayerHandle?
    private var onError: ((TStreamError) -> Void)?
    private var onReady: (() -> Void)?
    private var onProgress: ((TimeInterval) -> Void)?

    public init(url: URL, headers: [String: String] = [:], autoPlay: Bool = true) {
        self.url = url
        self.headers = headers
        self.autoPlay = autoPlay
    }

    /// Attaches an error handler invoked on the main thread.
    public func onPlaybackError(_ handler: @escaping (TStreamError) -> Void) -> TStreamPlayerView {
        var copy = self
        copy.onError = handler
        return copy
    }

    /// Invoked on the main thread once playback is ready to begin.
    public func onReadyToPlay(_ handler: @escaping () -> Void) -> TStreamPlayerView {
        var copy = self
        copy.onReady = handler
        return copy
    }

    /// Freeze (`true`) or resume (`false`) playback. Changes take effect once the
    /// clock is running; toggling before that is a no-op.
    public func paused(_ value: Bool) -> TStreamPlayerView {
        var copy = self
        copy.isPaused = value
        return copy
    }

    /// Reports elapsed playback seconds (relative to the first frame) on the main
    /// thread, ~4×/second while playing.
    public func onProgress(_ handler: @escaping (TimeInterval) -> Void) -> TStreamPlayerView {
        var copy = self
        copy.onProgress = handler
        return copy
    }

    /// Attaches an imperative handle for seeking.
    public func handle(_ handle: TStreamPlayerHandle) -> TStreamPlayerView {
        var copy = self
        copy.handle = handle
        return copy
    }

    public var body: some View {
        _TStreamPlayerContainer(url: url, headers: headers, autoPlay: autoPlay,
                                isPaused: isPaused, handle: handle, onError: onError,
                                onReady: onReady, onProgress: onProgress)
    }
}

/// Owns the `TStreamSampleBufferPlayer` for the lifetime of the view and bridges
/// its display layer into SwiftUI.
private struct _TStreamPlayerContainer: View {
    let url: URL
    let headers: [String: String]
    let autoPlay: Bool
    let isPaused: Bool
    let handle: TStreamPlayerHandle?
    let onError: ((TStreamError) -> Void)?
    let onReady: (() -> Void)?
    let onProgress: ((TimeInterval) -> Void)?

    @StateObject private var model = PlayerModel()

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                DisplayLayerView(layer: player.displayLayer)
            }
        }
        .onAppear {
            model.configure(url: url, headers: headers, autoPlay: autoPlay,
                            onError: onError, onReady: onReady, onProgress: onProgress)
            handle?.player = model.player
            model.setPaused(isPaused)
        }
        .onChange(of: isPaused) { paused in
            model.setPaused(paused)
        }
        .onDisappear {
            model.teardown()
        }
    }
}

private final class PlayerModel: ObservableObject {
    @Published private(set) var player: TStreamSampleBufferPlayer?

    func configure(url: URL, headers: [String: String], autoPlay: Bool,
                   onError: ((TStreamError) -> Void)?, onReady: (() -> Void)?,
                   onProgress: ((TimeInterval) -> Void)?) {
        guard player == nil else { return }
        let player = TStreamSampleBufferPlayer(url: url, headers: headers)
        player.onError = onError
        player.onReadyToPlay = onReady
        player.onProgress = onProgress
        self.player = player
        if autoPlay { player.play() }
    }

    func setPaused(_ paused: Bool) {
        if paused { player?.pause() } else { player?.resume() }
    }

    func teardown() {
        player?.stop()
        player = nil
    }
}

// MARK: - Display layer host

#if canImport(UIKit)
private struct DisplayLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.attach(layer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {
        uiView.attach(layer)
    }
}

final class SampleBufferHostView: UIView {
    private weak var attached: AVSampleBufferDisplayLayer?

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        guard attached !== displayLayer else { return }
        attached?.removeFromSuperlayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        layer.addSublayer(displayLayer)
        attached = displayLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attached?.frame = bounds
    }
}

#elseif canImport(AppKit)
private struct DisplayLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.attach(layer)
        return view
    }

    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {
        nsView.attach(layer)
    }
}

final class SampleBufferHostView: NSView {
    private weak var attached: AVSampleBufferDisplayLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        guard attached !== displayLayer else { return }
        attached?.removeFromSuperlayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        attached = displayLayer
    }

    override func layout() {
        super.layout()
        attached?.frame = bounds
    }
}
#endif
