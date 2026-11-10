import Foundation
#if os(iOS) || os(tvOS)
import AVFoundation
#endif

/// Puts the shared audio session into `.playback`, so a stream is audible with
/// the ringer off and keeps playing under the silent switch.
///
/// `setCategory` and `setActive` talk to the audio server synchronously and can
/// block for a noticeable time, more so while another session is active. On the
/// main thread that freezes the UI, so both run on a serial queue of their own.
/// The order of calls from different places is kept, and the player does not
/// wait: audio that arrives before activation simply starts a moment later.
public enum TStreamAudioSession {
    private static let queue = DispatchQueue(label: "TStreamKit.audioSession", qos: .userInitiated)

    public static func activateForPlayback() {
        #if os(iOS) || os(tvOS)
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
        #endif
    }
}
