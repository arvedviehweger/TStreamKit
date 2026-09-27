import Foundation
import QuartzCore

/// Wraps a live `MediaSource` with a rewindable buffer, so the viewer can pause
/// live TV and skip back into what has already been broadcast.
///
/// The wrapper records every access unit the inner source produces and, in
/// **live** mode, forwards it downstream unchanged — that path is exactly what
/// the player saw before timeshift existed. Pausing or rewinding switches it to
/// **replay** mode: the inner source keeps downloading and recording, while a
/// pacer feeds the player from the ring at real time. Catching up with the
/// recorded head switches it back to live.
///
/// Everything degrades safely: if the ring can't be created or a write fails,
/// the wrapper becomes a pass-through and live playback is unaffected.
///
/// All state is confined to `queue`.
final class TimeshiftMediaSource: MediaSource {
    weak var delegate: MediaSourceDelegate?
    var onError: ((TStreamError) -> Void)?
    /// Fired when the ring is dropped mid-playback after an I/O failure. The
    /// player has to flush: replayed and live packets sit minutes apart on the
    /// timeline, so without one the picture would freeze until the clock caught
    /// up. Delivered on this source's queue.
    var onBufferingEnded: (() -> Void)?

    private enum Mode { case live, replay }

    private let inner: MediaSource
    private let queue = DispatchQueue(label: "com.tstream.timeshift")
    private var buffer: TimeshiftBuffer?

    private var mode: Mode = .live
    /// Global buffer index of the next entry to emit while replaying.
    private var cursor = 0
    private var pumpScheduled = false
    /// The viewer pressed pause. Distinct from `backpressurePaused`: a hold
    /// keeps recording, while backpressure in live mode throttles the network.
    private var holdActive = false
    private var backpressurePaused = false
    private var stopped = false

    /// Real-time pacer for replay: the timestamp and wall clock the current
    /// stretch of replay was anchored at. Cleared whenever emission stops, so
    /// a pause never lets the pacer run ahead of what was actually played.
    private var anchorPTS: UInt64?
    private var anchorTime: CFTimeInterval?

    /// How far ahead of the pacer's clock units are handed to the player. Kept
    /// below the player's own low-water mark so the pacer, not the player's
    /// backpressure, is what regulates replay.
    private static let leadSeconds: Double = 1.0
    private static let tickSeconds: Double = 0.05
    /// Ceiling on units emitted per tick, so a long stall can't monopolise the
    /// queue trying to catch up in one go.
    private static let maxUnitsPerTick = 512

    private let availabilityLock = NSLock()
    private var _isAvailable = false
    private var _isPlayingLive = true

    /// False once the buffer is gone (never created, or an I/O failure), in
    /// which case the wrapper is a plain pass-through.
    var isAvailable: Bool {
        availabilityLock.lock(); defer { availabilityLock.unlock() }
        return _isAvailable
    }

    /// Whether the player is being fed straight from the network rather than
    /// from the ring.
    var isPlayingLive: Bool {
        availabilityLock.lock(); defer { availabilityLock.unlock() }
        return _isPlayingLive
    }

    /// Oldest and newest recorded timestamp, in 90 kHz ticks.
    var bufferedSpan: (earliest: UInt64, latest: UInt64)? { buffer?.span }

    init(wrapping inner: MediaSource, configuration: TimeshiftBuffer.Configuration) {
        self.inner = inner
        self.buffer = TimeshiftBuffer(configuration: configuration)
        inner.delegate = self
        inner.onError = { [weak self] error in self?.onError?(error) }
        setAvailable(buffer != nil)
        if buffer == nil {
            TStreamDiagnostics.log("timeshift: buffer unavailable, playing live only")
        }
    }

    // MARK: - MediaSource

    func start() { inner.start() }

    func stop() {
        queue.async {
            self.stopped = true
            self.buffer?.tearDown()
            self.buffer = nil
            self.setAvailable(false)
            self.delegate = nil
        }
        inner.stop()
        onError = nil
    }

    /// Backpressure from the player. While live this throttles the network, as
    /// it always has. While replaying it only idles the pacer — pausing the
    /// download there would punch a hole in the recording.
    func pause() {
        queue.async {
            guard !self.stopped else { return }
            self.backpressurePaused = true
            self.clearAnchor()
            if self.mode == .live { self.inner.pause() }
        }
    }

    func resume() {
        queue.async {
            guard !self.stopped else { return }
            self.backpressurePaused = false
            if self.mode == .live {
                self.inner.resume()
            } else {
                self.schedulePump()
            }
        }
    }

    /// A live stream has no length, so fraction seeking stays meaningless;
    /// rewinding goes through `seek(toTimestamp:)` instead.
    var isSeekable: Bool { false }

    func seek(toFraction fraction: Double, completion: @escaping () -> Void) {
        queue.async(execute: completion)
    }

    // MARK: - Timeshift control

    /// The viewer pressed pause. Stops feeding the player but keeps recording,
    /// so resuming continues from exactly where the picture froze.
    func beginHold() {
        queue.async {
            guard !self.stopped, self.buffer != nil else { return }
            self.holdActive = true
            self.clearAnchor()
            if self.mode == .live {
                // Everything recorded so far has already been forwarded, so the
                // replay cursor starts at the head.
                self.cursor = self.buffer?.endIndex ?? 0
                self.setMode(.replay)
            }
            // Recording has to continue through the pause, so undo any
            // throttling the live path applied.
            self.inner.resume()
        }
    }

    func endHold() {
        queue.async {
            guard !self.stopped else { return }
            self.holdActive = false
            self.clearAnchor()
            self.schedulePump()
        }
    }

    /// Restart playback at `timestamp` (90 kHz), snapped back to the nearest
    /// keyframe. `completion` fires on this source's queue once the new read
    /// position is live, matching the `MediaSource.seek` contract the player
    /// relies on to drop stale pre-seek data.
    func seek(toTimestamp timestamp: UInt64, completion: @escaping () -> Void) {
        queue.async {
            defer { completion() }
            guard !self.stopped, let buffer = self.buffer,
                  let index = buffer.indexOfSyncPoint(atOrBefore: timestamp) else { return }
            self.cursor = index
            self.holdActive = false
            self.backpressurePaused = false
            self.clearAnchor()
            self.setMode(.replay)
            self.schedulePump()
        }
    }

    /// Jump back to the live edge, dropping everything buffered in between.
    func returnToLive(completion: @escaping () -> Void) {
        queue.async {
            defer { completion() }
            guard !self.stopped else { return }
            self.cursor = self.buffer?.endIndex ?? 0
            self.holdActive = false
            self.backpressurePaused = false
            self.clearAnchor()
            self.setMode(.live)
            self.inner.resume()
        }
    }

    // MARK: - Replay pacer

    private func schedulePump() {
        guard !pumpScheduled, canEmit else { return }
        pumpScheduled = true
        queue.async { self.pump() }
    }

    private var canEmit: Bool {
        !stopped && mode == .replay && !holdActive && !backpressurePaused && buffer != nil
    }

    private func pump() {
        pumpScheduled = false
        guard canEmit, let buffer else { return }

        // Entries the ring has already reclaimed are gone; jump to what's left
        // rather than reading somebody else's bytes.
        if cursor < buffer.startIndex { cursor = buffer.startIndex; clearAnchor() }

        let now = CACurrentMediaTime()
        if anchorTime == nil {
            guard let entry = buffer.entry(at: cursor) else {
                // Nothing left to replay: we are at the recorded head, which is
                // the live edge.
                switchToLive()
                return
            }
            anchorPTS = entry.pts
            anchorTime = now
        }
        guard let anchorPTS, let anchorTime else { return }

        let elapsed = now - anchorTime + Self.leadSeconds
        let horizon = anchorPTS &+ UInt64(max(0, elapsed) * 90_000)

        var emitted = 0
        while emitted < Self.maxUnitsPerTick,
              let entry = buffer.entry(at: cursor),
              entry.pts <= horizon {
            emit(entry, from: buffer)
            cursor += 1
            emitted += 1
        }

        if buffer.entry(at: cursor) == nil, cursor >= buffer.endIndex {
            switchToLive()
            return
        }
        pumpScheduled = true
        queue.asyncAfter(deadline: .now() + Self.tickSeconds) { self.pump() }
    }

    private func emit(_ entry: TimeshiftBuffer.Entry, from buffer: TimeshiftBuffer) {
        guard let data = buffer.payload(for: entry) else { return }
        if entry.isVideo {
            guard let codec = videoCodec else { return }
            delegate?.mediaSource(self, didProduceVideo: data, codec: codec,
                                  pts: entry.pts, dts: entry.dts, isKeyframe: entry.isKeyframe)
        } else {
            delegate?.mediaSource(self, didProduceAudio:
                AccessUnit(data: data, pts: entry.pts, dts: entry.dts, isKeyframe: true))
        }
    }

    private func switchToLive() {
        setMode(.live)
        clearAnchor()
        if backpressurePaused { inner.pause() }
    }

    private func clearAnchor() {
        anchorPTS = nil
        anchorTime = nil
    }

    private func setMode(_ next: Mode) {
        mode = next
        availabilityLock.lock()
        _isPlayingLive = next == .live
        availabilityLock.unlock()
    }

    private func setAvailable(_ value: Bool) {
        availabilityLock.lock()
        _isAvailable = value
        availabilityLock.unlock()
    }

    /// Codec of the video stream, learned from the first packet. Replayed
    /// packets carry no codec of their own, so it is remembered here.
    private var videoCodec: VideoCodec?

    /// Drops the ring after an I/O failure and falls back to plain live
    /// playback rather than stranding the viewer on a frozen picture.
    private func disableBuffering() {
        guard buffer != nil else { return }
        TStreamDiagnostics.log("timeshift: disabling the buffer after an I/O failure")
        buffer?.tearDown()
        buffer = nil
        setAvailable(false)
        let wasReplaying = mode == .replay
        holdActive = false
        backpressurePaused = false
        setMode(.live)
        inner.resume()
        if wasReplaying { onBufferingEnded?() }
    }
}

// MARK: - Recording the inner source

extension TimeshiftMediaSource: MediaSourceDelegate {
    // Format descriptions are pipeline setup, not media: they are forwarded
    // straight through and never buffered. The player keeps them across a
    // flush, so a rewind doesn't need them again.
    func mediaSource(_ source: MediaSource, didParseVideoFormat codec: VideoCodec,
                     extradata: Data?, pixelAspect: PixelAspect?) {
        queue.async {
            self.videoCodec = codec
            self.delegate?.mediaSource(self, didParseVideoFormat: codec,
                                       extradata: extradata, pixelAspect: pixelAspect)
        }
    }

    func mediaSource(_ source: MediaSource, didProduceVideo data: Data, codec: VideoCodec,
                     pts: UInt64, dts: UInt64, isKeyframe: Bool) {
        queue.async {
            guard !self.stopped else { return }
            self.videoCodec = codec
            self.record(isVideo: true, data: data, pts: pts, dts: dts, isKeyframe: isKeyframe)
            guard self.mode == .live else { return }
            self.delegate?.mediaSource(self, didProduceVideo: data, codec: codec,
                                       pts: pts, dts: dts, isKeyframe: isKeyframe)
        }
    }

    func mediaSourceDidDetectAudioOnly(_ source: MediaSource) {
        queue.async {
            self.delegate?.mediaSourceDidDetectAudioOnly(self)
        }
    }

    func mediaSource(_ source: MediaSource, didParseAudioFormat format: AudioFormat) {
        queue.async {
            self.delegate?.mediaSource(self, didParseAudioFormat: format)
        }
    }

    func mediaSource(_ source: MediaSource, didProduceAudio unit: AccessUnit) {
        queue.async {
            guard !self.stopped else { return }
            self.record(isVideo: false, data: unit.data, pts: unit.pts,
                        dts: unit.dts, isKeyframe: true)
            guard self.mode == .live else { return }
            self.delegate?.mediaSource(self, didProduceAudio: unit)
        }
    }

    func mediaSource(_ source: MediaSource, didFail error: TStreamError) {
        queue.async {
            self.delegate?.mediaSource(self, didFail: error)
        }
    }

    private func record(isVideo: Bool, data: Data, pts: UInt64, dts: UInt64, isKeyframe: Bool) {
        guard let buffer else { return }
        let ok = buffer.append(isVideo: isVideo, data: data, pts: pts,
                               dts: dts, isKeyframe: isKeyframe)
        if !ok { disableBuffering() }
    }
}
