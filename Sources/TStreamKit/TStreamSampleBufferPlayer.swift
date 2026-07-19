import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Plays a raw HTTP MPEG-TS stream. Video is decoded by **libavcodec** (robust
/// error concealment + interlaced/non-IDR handling that VideoToolbox lacks for
/// German DVB broadcast) into `CVPixelBuffer`s rendered by an
/// `AVSampleBufferDisplayLayer`; audio (AAC / AC-3 / MP2→AAC) is decoded by the
/// system `AVSampleBufferAudioRenderer`. Both are driven by a shared
/// `AVSampleBufferRenderSynchronizer`.
final class TStreamSampleBufferPlayer: NSObject {
    /// The video output layer — host it in a view.
    let displayLayer = AVSampleBufferDisplayLayer()

    var onError: ((TStreamError) -> Void)?
    var onReadyToPlay: (() -> Void)?
    /// Reports elapsed playback seconds (relative to the first frame) ~4×/sec
    /// once the clock is running. Delivered on the main thread.
    var onProgress: ((TimeInterval) -> Void)?

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let source: TSDemuxSource
    /// Serializes video decode + display drain + all playback state.
    private let renderQueue = DispatchQueue(label: "com.tstream.render")
    /// Serializes the audio drain so refilling the audio renderer is never
    /// blocked behind a slow libavcodec video decode on `renderQueue` — under
    /// sustained HD load (and thermal throttling) that starved the renderer and
    /// produced the intermittent audio dropouts. All audio-only state below
    /// (`audioQueue`, `audioRequesting`, `audioFormatDesc`, `audioStopped`,
    /// `audioGateOpen`) is confined to this queue.
    private let audioRenderQueue = DispatchQueue(label: "com.tstream.audio")

    private let videoTimescale: CMTimeScale = 90_000

    // Video: libavcodec → CVPixelBuffer → display layer.
    private var ffDecoder: TStreamFFVideoDecoder?
    private var videoQueue: [CMSampleBuffer] = []
    private var sawVideo = false

    // Audio: compressed AAC/AC-3 → system audio renderer. Confined to
    // `audioRenderQueue`.
    private var audioFormatDesc: CMAudioFormatDescription?
    private var audioQueue: [CMSampleBuffer] = []
    /// Audio-side mirror of `stopped`, set on `audioRenderQueue`.
    private var audioStopped = false
    /// Gates audio ingest: audio only flows once video has been seen, and is
    /// closed again on seek until the first post-seek keyframe reopens it. This
    /// is the audio-queue-local stand-in for `sawVideo` + `discardingUntilSeek`,
    /// which live on `renderQueue`. Toggled via `openAudioGate` / `closeAudioGate`.
    private var audioGateOpen = false

    private var clockStarted = false
    /// User-initiated pause (distinct from the backpressure source pause). While
    /// set, the synchronizer rate is held at 0 so video *and* audio freeze.
    private var userPaused = false
    private var progressObserver: Any?
    /// PTS of the very first frame of the whole stream — the anchor for absolute
    /// position reporting. Unlike `firstVideoPTS` it is NOT reset on a seek, so
    /// `onProgress` keeps reporting the true offset within the recording.
    private var streamStartPTS: CMTime?
    /// True between requesting a seek and the source confirming the new request
    /// has started. While set, decoded frames are discarded so stale pre-seek
    /// data can't anchor the clock at the wrong position.
    private var discardingUntilSeek = false
    /// PTS anchor for the current segment (reset on every seek).
    private var firstVideoPTS: CMTime?
    private var latestVideoPTS: CMTime = .zero
    private let prerollSeconds = 1.0

    // Whether each renderer currently has an active media-data request. We arm
    // it only while there is data to drain and stop when empty — otherwise the
    // renderer calls the (empty) block in a tight loop and pins a CPU core.
    private var videoRequesting = false
    private var audioRequesting = false
    private var stopped = false

    // Backpressure: a recording downloads as fast as the link allows, so without
    // throttling every frame is decoded into an (uncompressed) CVPixelBuffer and
    // piled into `videoQueue` faster than the real-time clock drains it — the app
    // is OOM-killed within seconds. We suspend the network source once we are
    // `highWaterSeconds` ahead of the playback clock and resume below `lowWater`.
    private var sourcePaused = false
    private let highWaterSeconds = 4.0
    private let lowWaterSeconds = 2.0

    init(url: URL, headers: [String: String] = [:]) {
        self.source = TSDemuxSource(httpURL: url, headers: headers)
        super.init()
        source.rawVideoMode = true

        synchronizer.addRenderer(audioRenderer)
        synchronizer.addRenderer(displayLayer)

        source.delegate = self
        source.onError = { [weak self] error in
            DispatchQueue.main.async { self?.onError?(error) }
        }
    }

    deinit {
        if let progressObserver { synchronizer.removeTimeObserver(progressObserver) }
        displayLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        source.stop()
    }

    func play() {
        configureAudioSession()
        source.start()
    }

    /// Freeze playback (video + audio) by holding the synchronizer at rate 0.
    /// The network source pauses itself via backpressure once the frozen clock
    /// stops draining the buffer, so we don't keep downloading indefinitely.
    func pause() {
        renderQueue.async {
            guard !self.userPaused, !self.stopped else { return }
            self.userPaused = true
            // If the clock hasn't started yet, `startClockIfReady` will honour
            // `userPaused` and bring it up at rate 0 (first frame shown, frozen).
            if self.clockStarted { self.synchronizer.rate = 0 }
        }
    }

    /// Resume after `pause()`: restart the clock, re-arm the drains (they stop
    /// themselves when the display layer fills while paused) and let the
    /// backpressure check resume the network source once the buffer drains.
    func resume() {
        renderQueue.async {
            guard self.userPaused, !self.stopped else { return }
            self.userPaused = false
            guard self.clockStarted else { return }
            self.synchronizer.rate = 1
            self.armVideo()
            self.audioRenderQueue.async { self.armAudio() }
            self.scheduleResumeCheck()
        }
    }

    /// Seek to a fraction (0…1) of the recording. Approximate / GOP-accurate:
    /// the byte offset is `fraction × totalBytes`, the source resyncs to the
    /// next TS packet, and decoding resumes at the next keyframe. Absolute
    /// position (`onProgress`) stays correct because it is anchored to
    /// `streamStartPTS`, not the per-segment `firstVideoPTS`.
    func seek(toFraction fraction: Double) {
        let f = min(max(fraction, 0), 1)
        renderQueue.async {
            guard !self.stopped else { return }
            let total = self.source.totalBytes
            guard total > 0 else { return }
            self.flushForSeek()
            let offset = Int64(Double(total) * f)
            self.source.seek(toByteOffset: offset) { [weak self] in
                self?.renderQueue.async { self?.discardingUntilSeek = false }
            }
        }
    }

    /// Tear down all decode/render state for the current position so the seeked
    /// segment starts clean. Keeps `streamStartPTS` (absolute anchor) and the
    /// audio format. Runs on `renderQueue`.
    private func flushForSeek() {
        if let observer = progressObserver {
            synchronizer.removeTimeObserver(observer)
            progressObserver = nil
        }
        synchronizer.rate = 0
        displayLayer.stopRequestingMediaData(); videoRequesting = false
        displayLayer.flush()
        videoQueue.removeAll()
        // Audio state lives on its own queue; flush it there and close the gate
        // so no stale pre-seek audio plays until the first post-seek keyframe.
        closeAudioGate(flush: true)
        ffDecoder = nil          // fresh decoder waits for the next keyframe
        clockStarted = false
        firstVideoPTS = nil
        latestVideoPTS = .zero
        sawVideo = false
        sourcePaused = false
        discardingUntilSeek = true
    }

    func stop() {
        renderQueue.async {
            guard !self.stopped else { return }
            self.stopped = true
            if let observer = self.progressObserver {
                self.synchronizer.removeTimeObserver(observer)
                self.progressObserver = nil
            }
            self.displayLayer.stopRequestingMediaData()
            self.videoRequesting = false
            self.videoQueue.removeAll()
            self.synchronizer.setRate(0, time: .invalid)
            self.displayLayer.flushAndRemoveImage()
            self.ffDecoder = nil
        }
        audioRenderQueue.async {
            self.audioStopped = true
            self.audioGateOpen = false
            self.audioRenderer.stopRequestingMediaData()
            self.audioRequesting = false
            self.audioQueue.removeAll()
            self.audioRenderer.flush()
            self.audioFormatDesc = nil
        }
        source.stop()
    }

    // MARK: - Drain (arm only while there's data; stop when empty)

    private func armVideo() {
        guard !stopped, !videoRequesting else { return }
        videoRequesting = true
        displayLayer.requestMediaDataWhenReady(on: renderQueue) { [weak self] in
            guard let self else { return }
            while self.displayLayer.isReadyForMoreMediaData {
                guard !self.stopped else {
                    self.displayLayer.stopRequestingMediaData()
                    self.videoRequesting = false
                    return
                }
                guard !self.videoQueue.isEmpty else {
                    self.displayLayer.stopRequestingMediaData()
                    self.videoRequesting = false
                    return
                }
                self.displayLayer.enqueue(self.videoQueue.removeFirst())
            }
        }
    }

    /// Runs on `audioRenderQueue` so a slow video decode on `renderQueue` can
    /// never delay refilling the audio renderer.
    private func armAudio() {
        guard !audioStopped, !audioRequesting else { return }
        audioRequesting = true
        audioRenderer.requestMediaDataWhenReady(on: audioRenderQueue) { [weak self] in
            guard let self else { return }
            while self.audioRenderer.isReadyForMoreMediaData {
                guard !self.audioStopped else {
                    self.audioRenderer.stopRequestingMediaData()
                    self.audioRequesting = false
                    return
                }
                guard !self.audioQueue.isEmpty else {
                    self.audioRenderer.stopRequestingMediaData()
                    self.audioRequesting = false
                    return
                }
                self.audioRenderer.enqueue(self.audioQueue.removeFirst())
            }
        }
    }

    /// Open/close the audio gate (on `audioRenderQueue`). Closing optionally
    /// flushes the renderer and drops any buffered audio — used on seek/stop.
    private func openAudioGate() {
        audioRenderQueue.async { self.audioGateOpen = true }
    }

    private func closeAudioGate(flush: Bool) {
        audioRenderQueue.async {
            self.audioGateOpen = false
            guard flush else { return }
            self.audioRenderer.stopRequestingMediaData()
            self.audioRequesting = false
            self.audioRenderer.flush()
            self.audioQueue.removeAll()
        }
    }

    // MARK: - Backpressure (on renderQueue)

    /// Seconds of video decoded ahead of the playback position. Before the clock
    /// starts we measure against the first PTS (we're still prerolling).
    private func bufferedAheadSeconds() -> Double {
        guard let firstVideoPTS else { return 0 }
        let clock = clockStarted ? synchronizer.currentTime() : firstVideoPTS
        return CMTimeGetSeconds(latestVideoPTS - clock)
    }

    private func updateBackpressure() {
        guard !stopped, !sourcePaused else { return }
        guard bufferedAheadSeconds() >= highWaterSeconds else { return }
        sourcePaused = true
        source.pause()
        scheduleResumeCheck()
    }

    /// While paused the drain blocks may stop firing (the display layer is full),
    /// so poll the clock until the buffer drains, then resume the download.
    private func scheduleResumeCheck() {
        renderQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.sourcePaused, !self.stopped else { return }
            if self.bufferedAheadSeconds() <= self.lowWaterSeconds {
                self.sourcePaused = false
                self.source.resume()
            } else {
                self.scheduleResumeCheck()
            }
        }
    }

    private func startClockIfReady() {
        guard !stopped, !clockStarted, let firstVideoPTS else { return }
        guard CMTimeGetSeconds(latestVideoPTS - firstVideoPTS) >= prerollSeconds else { return }
        clockStarted = true
        // Honour a pause requested during buffering: bring the clock up frozen
        // (the first frame is presented) instead of auto-playing.
        synchronizer.setRate(userPaused ? 0 : 1.0, time: firstVideoPTS)
        progressObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            // Report absolute offset within the recording (survives seeks).
            guard let self, let base = self.streamStartPTS else { return }
            self.onProgress?(max(0, CMTimeGetSeconds(time - base)))
        }
        DispatchQueue.main.async { [weak self] in self?.onReadyToPlay?() }
        TStreamDiagnostics.log("sbplayer: clock started at \(CMTimeGetSeconds(firstVideoPTS))s")
    }

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }
}

// MARK: - Demuxer consumption

extension TStreamSampleBufferPlayer: TSDemuxerDelegate {
    // Raw-video mode: these two don't fire, but the protocol requires them.
    func demuxer(_ d: TSDemuxer, didParseVideoFormat format: VideoFormat) {}
    func demuxer(_ d: TSDemuxer, didProduceVideo unit: AccessUnit) {}

    func demuxer(_ d: TSDemuxer, didProduceRawVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        renderQueue.async { [weak self] in self?.ingestRawVideo(data, codec: codec, pts: pts, dts: dts) }
    }

    func demuxer(_ d: TSDemuxer, didParseAudioFormat format: AudioFormat) {
        let desc = Self.makeAudioFormatDescription(format)
        audioRenderQueue.async { [weak self] in
            guard let self, !self.audioStopped else { return }
            self.audioFormatDesc = desc
        }
    }

    func demuxer(_ d: TSDemuxer, didProduceAudio unit: AccessUnit) {
        audioRenderQueue.async { [weak self] in self?.ingestAudio(unit) }
    }

    func demuxer(_ d: TSDemuxer, didFail error: TStreamError) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    // MARK: ingest (video on renderQueue, audio on audioRenderQueue)

    private func ingestRawVideo(_ data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        guard !stopped, !discardingUntilSeek else { return }
        if ffDecoder == nil {
            ffDecoder = TStreamFFVideoDecoder(codec: codec)
            if ffDecoder == nil {
                DispatchQueue.main.async { [weak self] in self?.onError?(.unsupportedCodec("video decoder init failed")) }
                return
            }
        }
        guard let ffDecoder else { return }
        if !sawVideo { sawVideo = true; openAudioGate() }
        for frame in ffDecoder.decode(data, pts: Int64(pts), dts: Int64(dts)) {
            enqueueVideoFrame(frame)
        }
    }

    private func enqueueVideoFrame(_ frame: TStreamFFVideoDecoder.DecodedFrame) {
        guard !stopped else { return }
        let pts = CMTime(value: frame.pts, timescale: videoTimescale)
        // Duration unknown per frame (25p vs 50p after deinterlace) — the
        // synchronizer drives display from PTS, so leave it invalid.
        guard let sample = Self.makeVideoSampleBuffer(
            pixelBuffer: frame.pixelBuffer, pts: pts, duration: .invalid) else { return }
        if streamStartPTS == nil { streamStartPTS = pts }
        if firstVideoPTS == nil { firstVideoPTS = pts }
        latestVideoPTS = pts
        videoQueue.append(sample)
        armVideo()
        startClockIfReady()
        updateBackpressure()
    }

    /// On `audioRenderQueue`. `audioGateOpen` stands in for `sawVideo` +
    /// `discardingUntilSeek`: it opens once video is seen and closes on seek.
    private func ingestAudio(_ unit: AccessUnit) {
        guard !audioStopped, audioGateOpen, let desc = audioFormatDesc else { return }
        guard let sample = Self.makeCompressedSampleBuffer(
            data: unit.data, formatDescription: desc,
            pts: CMTime(value: Int64(unit.pts), timescale: videoTimescale)) else { return }
        audioQueue.append(sample)
        armAudio()
    }
}

// MARK: - CoreMedia construction

private extension TStreamSampleBufferPlayer {
    static func makeVideoSampleBuffer(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc) == noErr, let formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    static func makeAudioFormatDescription(_ format: AudioFormat) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Float64(format.sampleRate)
        asbd.mChannelsPerFrame = UInt32(max(format.channels, 1))
        // AAC/MP2 use an AudioSpecificConfig magic cookie; AC-3 takes none (the
        // `dac3` box is MP4-only and is not a Core Audio cookie).
        var cookie: [UInt8] = []
        switch format.codec {
        case .ac3:
            asbd.mFormatID = kAudioFormatAC3
            asbd.mFramesPerPacket = UInt32(format.samplesPerFrame)   // 1536
        case .eac3:
            asbd.mFormatID = kAudioFormatEnhancedAC3
            asbd.mFramesPerPacket = UInt32(format.samplesPerFrame)   // blocks × 256
        case .aac, .mp2:
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
            asbd.mFramesPerPacket = 1024
            cookie = [UInt8](format.decoderConfig)
        }
        var desc: CMAudioFormatDescription?
        _ = cookie.withUnsafeBufferPointer { c in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: c.count, magicCookie: c.baseAddress,
                extensions: nil, formatDescriptionOut: &desc)
        }
        return desc
    }

    static func makeCompressedSampleBuffer(data: Data, formatDescription: CMFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let bytes = [UInt8](data)
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = bytes.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}
