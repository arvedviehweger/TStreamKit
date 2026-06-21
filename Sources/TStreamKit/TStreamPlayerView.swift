import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A SwiftUI view that plays an HTTP MPEG-TS stream through the TStream pipeline.
///
/// ```swift
/// struct PlayerScreen: View {
///     var body: some View {
///         TStreamPlayerView(url: URL(string: "http://tvheadend:9981/stream/channel/1")!)
///     }
/// }
/// ```
public struct TStreamPlayerView: View {
    private let url: URL
    private let autoPlay: Bool
    private var onError: ((TStreamError) -> Void)?
    private var onReady: (() -> Void)?

    public init(url: URL, autoPlay: Bool = true) {
        self.url = url
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

    public var body: some View {
        _TStreamPlayerContainer(url: url, autoPlay: autoPlay, onError: onError, onReady: onReady)
    }
}

/// Owns the `TStreamPlayer` for the lifetime of the view and bridges the
/// platform player layer into SwiftUI.
private struct _TStreamPlayerContainer: View {
    let url: URL
    let autoPlay: Bool
    let onError: ((TStreamError) -> Void)?
    let onReady: (() -> Void)?

    @StateObject private var model = PlayerModel()

    var body: some View {
        PlayerLayerView(player: model.player)
            .onAppear {
                model.configure(url: url, autoPlay: autoPlay, onError: onError, onReady: onReady)
            }
            .onDisappear {
                model.teardown()
            }
    }
}

private final class PlayerModel: ObservableObject {
    private(set) var player = AVPlayer()
    private var tstream: TStreamPlayer?

    func configure(url: URL, autoPlay: Bool, onError: ((TStreamError) -> Void)?, onReady: (() -> Void)?) {
        guard tstream == nil else { return }
        do {
            let tstream = try TStreamPlayer(url: url)
            tstream.onError = onError
            tstream.onReadyToPlay = onReady
            self.tstream = tstream
            self.player = tstream.player
            objectWillChange.send()
            if autoPlay { tstream.play() }
        } catch let error as TStreamError {
            onError?(error)
        } catch {
            onError?(.invalidURL(url.absoluteString))
        }
    }

    func teardown() {
        tstream?.stop()
        tstream = nil
    }
}

// MARK: - Platform player layer

#if canImport(UIKit)
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHostView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
    }
}

#elseif canImport(AppKit)
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif
