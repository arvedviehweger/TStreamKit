#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
import Foundation

/// Picture in Picture for the sample-buffer player.
///
/// `AVPictureInPictureController` normally wants an `AVPlayerLayer`, which this
/// pipeline deliberately doesn't have. Its *sample buffer* content source is
/// the way in: the same `AVSampleBufferDisplayLayer` the player already renders
/// into becomes the PiP window's content, and this object supplies the playback
/// state PiP needs to draw its controls.
///
/// PiP needs the `audio` background mode in the host app's Info.plist, the same
/// one background audio needs — without it the window closes the moment the app
/// leaves the foreground.
final class TStreamPictureInPicture: NSObject {
    /// Whether the device can do PiP at all (iPhones in Low Power Mode and some
    /// older hardware cannot).
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Reports the window opening and closing, on the main thread.
    var onStateChange: ((Bool) -> Void)?
    /// What PiP's skip buttons should do. Left to the host because only it
    /// knows whether this is a live stream to rewind or a recording to seek in.
    var onSkip: ((TimeInterval) -> Void)?

    private weak var player: TStreamSampleBufferPlayer?
    private var controller: AVPictureInPictureController?

    init(player: TStreamSampleBufferPlayer, layer: AVSampleBufferDisplayLayer) {
        self.player = player
        super.init()
        guard Self.isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
        // PiP has to know when the play/pause state changed under it, or its
        // button keeps showing the old one.
        player.onPlaybackStateChange = { [weak self] in
            DispatchQueue.main.async { self?.controller?.invalidatePlaybackState() }
        }
    }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Whether the system may float the window automatically when the app is
    /// backgrounded, instead of only on an explicit request. iOS only: on macOS
    /// the window is always opened deliberately.
    func setAutomatic(_ automatic: Bool) {
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = automatic
        #endif
    }

    func start() {
        guard let controller, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// Give up the window and the controller for good.
    ///
    /// Stopping is not enough on its own: a controller that is still alive and
    /// still armed for automatic start will open a window the next time the app
    /// is backgrounded — over a display layer that was flushed when the player
    /// was torn down, which is a black rectangle. So the automatic start is
    /// disarmed first, then the controller is dropped along with the content
    /// source holding the layer.
    func invalidate() {
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller?.contentSource = nil
        controller = nil
        player?.onPlaybackStateChange = nil
        player?.setPictureInPictureActive(false)
        player = nil
        onStateChange = nil
        onSkip = nil
    }
}

// MARK: - Playback state for the PiP window

extension TStreamPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        guard let player else { return }
        if playing { player.resume() } else { player.pause() }
    }

    /// An unbounded range is what tells PiP this is live, so it draws play,
    /// pause and skip rather than a scrubber it could not honour.
    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController) -> Bool {
        player?.isPausedByUser ?? false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // The display layer scales itself; nothing to do.
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) {
        onSkip?(CMTimeGetSeconds(skipInterval))
        completion()
    }
}

// MARK: - Window lifecycle

extension TStreamPictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController) {
        // Told before the app is backgrounded, so the player never suspends
        // video that is about to appear in the PiP window.
        player?.setPictureInPictureActive(true)
        onStateChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController) {
        player?.setPictureInPictureActive(false)
        onStateChange?(false)
    }

    /// The window's "back to app" button. The player view was never torn down
    /// — the PiP window was floating over it — so there is nothing to rebuild
    /// and the system is told the UI is ready. Leaving this unimplemented makes
    /// the handover visibly stall.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
            completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error) {
        TStreamDiagnostics.log("pip: failed to start — \(error.localizedDescription)")
        player?.setPictureInPictureActive(false)
        onStateChange?(false)
    }
}
#endif
