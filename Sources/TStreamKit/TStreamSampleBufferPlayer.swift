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

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let source: TSDemuxSource
    private let renderQueue = DispatchQueue(label: "com.tstream.render")

    private let videoTimescale: CMTimeScale = 90_000

    // Video: libavcodec → CVPixelBuffer → display layer.
    private var ffDecoder: TStreamFFVideoDecoder?
    private var videoQueue: [CMSampleBuffer] = []
    private var sawVideo = false

    // Audio: compressed AAC/AC-3 → system audio renderer.
    private var audioFormatDesc: CMAudioFormatDescription?
    private var audioQueue: [CMSampleBuffer] = []

    private var clockStarted = false
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
        displayLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        source.stop()
    }

    func play() {
        configureAudioSession()
        source.start()
    }

    func stop() {
        renderQueue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.displayLayer.stopRequestingMediaData()
            self.audioRenderer.stopRequestingMediaData()
            self.videoRequesting = false
            self.audioRequesting = false
            self.videoQueue.removeAll()
            self.audioQueue.removeAll()
            self.synchronizer.setRate(0, time: .invalid)
            self.displayLayer.flushAndRemoveImage()
            self.audioRenderer.flush()
            self.ffDecoder = nil
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

    private func armAudio() {
        guard !stopped, !audioRequesting else { return }
        audioRequesting = true
        audioRenderer.requestMediaDataWhenReady(on: renderQueue) { [weak self] in
            guard let self else { return }
            while self.audioRenderer.isReadyForMoreMediaData {
                guard !self.stopped else {
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
        synchronizer.setRate(1.0, time: firstVideoPTS)
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
        renderQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.audioFormatDesc = desc
        }
    }

    func demuxer(_ d: TSDemuxer, didProduceAudio unit: AccessUnit) {
        renderQueue.async { [weak self] in self?.ingestAudio(unit) }
    }

    func demuxer(_ d: TSDemuxer, didFail error: TStreamError) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    // MARK: ingest (on renderQueue)

    private func ingestRawVideo(_ data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        guard !stopped else { return }
        if ffDecoder == nil {
            ffDecoder = TStreamFFVideoDecoder(codec: codec)
            if ffDecoder == nil {
                DispatchQueue.main.async { [weak self] in self?.onError?(.unsupportedCodec("video decoder init failed")) }
                return
            }
        }
        guard let ffDecoder else { return }
        sawVideo = true
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
        if firstVideoPTS == nil { firstVideoPTS = pts }
        latestVideoPTS = pts
        videoQueue.append(sample)
        armVideo()
        startClockIfReady()
        updateBackpressure()
    }

    private func ingestAudio(_ unit: AccessUnit) {
        guard !stopped else { return }
        guard sawVideo, let desc = audioFormatDesc else { return }
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
