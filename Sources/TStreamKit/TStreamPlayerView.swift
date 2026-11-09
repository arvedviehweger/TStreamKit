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
///         TStreamPlayerView(url: URL(string: "http://server:9981/stream/channel/1")!)
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

    /// Skip inside the live buffer, relative to the current position; negative
    /// values rewind. Does nothing unless the view was given a
    /// `TStreamTimeshiftConfiguration`.
    public func skipTimeshift(by seconds: TimeInterval) {
        player?.timeshiftSkip(by: seconds)
    }

    /// Abandon the buffered position and rejoin the broadcast live.
    public func returnToLive() {
        player?.timeshiftReturnToLive()
    }

    /// Switch to another sound track, by `TStreamAudioTrack.id`.
    public func selectAudioTrack(id: Int) {
        player?.selectAudioTrack(id: id)
    }

    // MARK: - Picture in Picture

    #if os(iOS) || os(macOS)
    /// Whether this device can float the picture over other apps at all. False
    /// on hardware without Picture in Picture, and while Low Power Mode has it
    /// switched off.
    public var isPictureInPictureSupported: Bool { TStreamPictureInPicture.isSupported }

    /// Open the Picture in Picture window. Needs `.pictureInPicture(true)` on
    /// the view, and the `audio` background mode in the app's Info.plist.
    public func startPictureInPicture() { pictureInPicture?.start() }

    /// Close it and bring the picture back inline.
    public func stopPictureInPicture() { pictureInPicture?.stop() }

    public var isPictureInPictureActive: Bool { pictureInPicture?.isActive ?? false }

    /// Weak on purpose. The handle is `@State` in the host view and outlives
    /// the player's teardown; holding this strongly kept a controller alive
    /// that was still armed to open a window, and it opened a black one over
    /// the layer the closed player had flushed.
    weak var pictureInPicture: TStreamPictureInPicture?
    #endif
}

public struct TStreamPlayerView: View {
    private let url: URL
    private let headers: [String: String]
    private var credential: URLCredential?
    private let autoPlay: Bool
    private var isPaused: Bool = false
    private var handle: TStreamPlayerHandle?
    private var onError: ((TStreamError) -> Void)?
    private var onReady: (() -> Void)?
    private var onAudioOnly: (() -> Void)?
    private var onAudioTracks: (([TStreamAudioTrack], Int?) -> Void)?
    private var onProgress: ((TimeInterval) -> Void)?
    private var timeshiftConfiguration: TStreamTimeshiftConfiguration?
    private var onTimeshiftStatus: ((TStreamTimeshiftStatus) -> Void)?
    private var isVideoSuspended = false
    private var pictureInPictureEnabled = false
    private var startsPictureInPictureAutomatically = true
    private var onPictureInPictureChange: ((Bool) -> Void)?
    private var onSkipRequest: ((TimeInterval) -> Void)?

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

    /// Called on the main thread when the stream turns out to carry no video, so
    /// the host can show something other than an empty display layer. Fires
    /// before playback starts, and only for a stream that really has no video.
    public func onAudioOnly(_ handler: @escaping () -> Void) -> TStreamPlayerView {
        var copy = self
        copy.onAudioOnly = handler
        return copy
    }

    /// Reports the sound tracks the stream offers and which one is playing, on
    /// the main thread. A stream with one track reports one; a container that
    /// offers no choice reports none.
    public func onAudioTracks(
        _ handler: @escaping ([TStreamAudioTrack], Int?) -> Void
    ) -> TStreamPlayerView {
        var copy = self
        copy.onAudioTracks = handler
        return copy
    }

    /// Credentials for an HTTP auth challenge.
    ///
    /// An `Authorization` header passed to `init` covers Basic and saves a round
    /// trip, but a server configured for Digest never accepts it: it answers
    /// `401` and closes the connection, which arrives as a transport failure
    /// rather than as an auth error. Give the credentials here and the challenge
    /// is answered properly, whichever scheme the server asks for.
    public func credential(_ credential: URLCredential?) -> TStreamPlayerView {
        var copy = self
        copy.credential = credential
        return copy
    }

    /// Records the live stream to a disk ring so it can be paused and rewound.
    /// Only meaningful for a live source; a recording is already seekable.
    public func timeshift(_ configuration: TStreamTimeshiftConfiguration) -> TStreamPlayerView {
        var copy = self
        copy.timeshiftConfiguration = configuration
        return copy
    }

    /// Reports the live buffer's state on the main thread, twice a second.
    public func onTimeshiftStatus(
        _ handler: @escaping (TStreamTimeshiftStatus) -> Void
    ) -> TStreamPlayerView {
        var copy = self
        copy.onTimeshiftStatus = handler
        return copy
    }

    /// Turn video off while audio keeps playing — set this when the app leaves
    /// the foreground and it holds the `audio` background mode.
    ///
    /// The picture can't be drawn with the screen off anyway, and the display
    /// layer stops asking for frames there, which would stall the pipeline and
    /// cut the sound. Ignored while the Picture in Picture window is up.
    public func videoSuspended(_ suspended: Bool) -> TStreamPlayerView {
        var copy = self
        copy.isVideoSuspended = suspended
        return copy
    }

    /// Allow the picture to float over other apps.
    ///
    /// `automatically` lets the system open the window when the app is
    /// backgrounded; turn it off to open it only from `startPictureInPicture()`.
    public func pictureInPicture(_ enabled: Bool,
                                 automatically: Bool = true) -> TStreamPlayerView {
        var copy = self
        copy.pictureInPictureEnabled = enabled
        copy.startsPictureInPictureAutomatically = automatically
        return copy
    }

    /// Reports the Picture in Picture window opening and closing.
    public func onPictureInPictureChange(
        _ handler: @escaping (Bool) -> Void
    ) -> TStreamPlayerView {
        var copy = self
        copy.onPictureInPictureChange = handler
        return copy
    }

    /// Handles the skip buttons in the Picture in Picture window. Left to the
    /// host because only it knows whether this is a live stream to rewind or a
    /// recording to seek within.
    public func onSkipRequest(
        _ handler: @escaping (TimeInterval) -> Void
    ) -> TStreamPlayerView {
        var copy = self
        copy.onSkipRequest = handler
        return copy
    }

    public var body: some View {
        _TStreamPlayerContainer(url: url, headers: headers, credential: credential,
                                autoPlay: autoPlay,
                                isPaused: isPaused, handle: handle, onError: onError,
                                onReady: onReady, onAudioOnly: onAudioOnly,
                                onAudioTracks: onAudioTracks, onProgress: onProgress,
                                timeshiftConfiguration: timeshiftConfiguration,
                                onTimeshiftStatus: onTimeshiftStatus,
                                isVideoSuspended: isVideoSuspended,
                                pictureInPictureEnabled: pictureInPictureEnabled,
                                startsPictureInPictureAutomatically: startsPictureInPictureAutomatically,
                                onPictureInPictureChange: onPictureInPictureChange,
                                onSkipRequest: onSkipRequest)
    }
}

/// Owns the `TStreamSampleBufferPlayer` for the lifetime of the view and bridges
/// its display layer into SwiftUI.
private struct _TStreamPlayerContainer: View {
    let url: URL
    let headers: [String: String]
    let credential: URLCredential?
    let autoPlay: Bool
    let isPaused: Bool
    let handle: TStreamPlayerHandle?
    let onError: ((TStreamError) -> Void)?
    let onReady: (() -> Void)?
    let onAudioOnly: (() -> Void)?
    let onAudioTracks: (([TStreamAudioTrack], Int?) -> Void)?
    let onProgress: ((TimeInterval) -> Void)?
    let timeshiftConfiguration: TStreamTimeshiftConfiguration?
    let onTimeshiftStatus: ((TStreamTimeshiftStatus) -> Void)?
    let isVideoSuspended: Bool
    let pictureInPictureEnabled: Bool
    let startsPictureInPictureAutomatically: Bool
    let onPictureInPictureChange: ((Bool) -> Void)?
    let onSkipRequest: ((TimeInterval) -> Void)?

    @StateObject private var model = PlayerModel()

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                DisplayLayerView(layer: player.displayLayer)
            }
        }
        .onAppear {
            model.configure(url: url, headers: headers, credential: credential,
                            autoPlay: autoPlay,
                            onError: onError, onReady: onReady, onAudioOnly: onAudioOnly,
                            onAudioTracks: onAudioTracks,
                            onProgress: onProgress,
                            timeshift: timeshiftConfiguration,
                            onTimeshiftStatus: onTimeshiftStatus)
            handle?.player = model.player
            model.setPaused(isPaused)
            #if os(iOS) || os(macOS)
            if pictureInPictureEnabled {
                model.enablePictureInPicture(automatically: startsPictureInPictureAutomatically,
                                             onChange: onPictureInPictureChange,
                                             onSkip: onSkipRequest)
                handle?.pictureInPicture = model.pictureInPicture
            }
            #endif
            model.setVideoSuspended(isVideoSuspended)
        }
        .onChange(of: isPaused) { paused in
            model.setPaused(paused)
        }
        .onChange(of: isVideoSuspended) { suspended in
            model.setVideoSuspended(suspended)
        }
        .onDisappear {
            model.teardown()
        }
    }
}

private final class PlayerModel: ObservableObject {
    @Published private(set) var player: TStreamSampleBufferPlayer?

    func configure(url: URL, headers: [String: String], credential: URLCredential?,
                   autoPlay: Bool,
                   onError: ((TStreamError) -> Void)?, onReady: (() -> Void)?,
                   onAudioOnly: (() -> Void)?,
                   onAudioTracks: (([TStreamAudioTrack], Int?) -> Void)?,
                   onProgress: ((TimeInterval) -> Void)?,
                   timeshift: TStreamTimeshiftConfiguration?,
                   onTimeshiftStatus: ((TStreamTimeshiftStatus) -> Void)?) {
        guard player == nil else { return }
        let player = TStreamSampleBufferPlayer(url: url, headers: headers,
                                               credential: credential, timeshift: timeshift)
        player.onError = onError
        player.onReadyToPlay = { [weak self] in
            #if os(iOS) || os(macOS)
            self?.armAutomaticPictureInPicture()
            #endif
            onReady?()
        }
        // A radio channel would otherwise float a black window the moment the
        // app is backgrounded: the automatic start is armed before anyone knows
        // whether the stream carries video.
        player.onAudioOnly = { [weak self] in
            #if os(iOS) || os(macOS)
            self?.pictureInPicture?.setAutomatic(false)
            #endif
            onAudioOnly?()
        }
        player.onAudioTracks = onAudioTracks
        player.onProgress = onProgress
        player.onTimeshiftStatus = onTimeshiftStatus
        self.player = player
        if autoPlay { player.play() }
    }

    func setPaused(_ paused: Bool) {
        if paused { player?.pause() } else { player?.resume() }
    }

    func setVideoSuspended(_ suspended: Bool) {
        player?.setVideoSuspended(suspended)
    }

    #if os(iOS) || os(macOS)
    private(set) var pictureInPicture: TStreamPictureInPicture?

    /// Whether the host asked for the window to open by itself. Held rather
    /// than applied straight away — see `armAutomaticPictureInPicture`.
    private var wantsAutomaticPictureInPicture = false

    func enablePictureInPicture(automatically: Bool,
                                onChange: ((Bool) -> Void)?,
                                onSkip: ((TimeInterval) -> Void)?) {
        guard pictureInPicture == nil, let player else { return }
        let pip = TStreamPictureInPicture(player: player, layer: player.displayLayer)
        pip.onStateChange = onChange
        pip.onSkip = onSkip
        // Deliberately not armed yet: a stream that never produces a frame —
        // one that fails, or that the viewer closes while it is still starting
        // — would otherwise float an empty window as soon as the app is
        // backgrounded. Arming waits for the first frame.
        pip.setAutomatic(false)
        wantsAutomaticPictureInPicture = automatically
        pictureInPicture = pip
    }

    private func armAutomaticPictureInPicture() {
        guard wantsAutomaticPictureInPicture else { return }
        pictureInPicture?.setAutomatic(true)
    }
    #endif

    func teardown() {
        #if os(iOS) || os(macOS)
        pictureInPicture?.invalidate()
        pictureInPicture = nil
        #endif
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
