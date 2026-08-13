import Foundation
import CFFVideoDecoder

/// Matroska/WebM and MP4 via libavformat.
///
/// libavformat pulls: it calls a read callback whenever it wants bytes. The
/// network side pushes. So the bytes handed to `consume` go into a buffer, a
/// dedicated thread runs the demux loop, and the read callback blocks on that
/// buffer when it runs dry. Backpressure still works, because a suspended
/// download simply means the callback waits longer.
final class FFStreamDemuxer: StreamDemuxer {
    weak var output: StreamDemuxerOutput?

    /// Guards `buffer`, `finished` and `stopped`, and wakes the read callback.
    private let condition = NSCondition()
    private var buffer = Data()
    private var finished = false
    private var stopped = false

    private var demuxer: OpaquePointer?
    private var thread: Thread?
    private var started = false

    /// How much undemuxed input to hold before the producer is told to wait.
    /// The player's own backpressure normally keeps us well under this; it is a
    /// backstop for the window between the buffer filling and the download
    /// actually suspending.
    private let highWaterBytes = 8 * 1024 * 1024

    deinit {
        stop()
    }

    // MARK: - StreamDemuxer

    func consume(_ data: Data) {
        condition.lock()
        buffer.append(data)
        condition.signal()
        let shouldStart = !started && !stopped
        if shouldStart { started = true }
        condition.unlock()

        if shouldStart { startDemuxThread() }
    }

    /// libavformat cannot resync mid-container the way the TS parser can, so a
    /// seek has to rebuild the demuxer against the new byte position.
    func reset() {
        teardown()
        condition.lock()
        buffer.removeAll(keepingCapacity: false)
        finished = false
        stopped = false
        started = false
        condition.unlock()
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        let alreadyStopped = stopped
        stopped = true
        condition.broadcast()
        condition.unlock()
        guard !alreadyStopped else { return }
        teardown()
    }

    /// Unblocks the demux thread and waits for it to leave libavformat before
    /// freeing anything it might still be touching.
    private func teardown() {
        if let demuxer { cff_demux_interrupt(demuxer) }
        condition.lock()
        condition.broadcast()
        condition.unlock()

        while let thread, !thread.isFinished {
            Thread.sleep(forTimeInterval: 0.005)
        }
        thread = nil

        if let demuxer {
            cff_demux_destroy(demuxer)
            self.demuxer = nil
        }
    }

    /// True while the buffer is over the backstop limit.
    var isSaturated: Bool {
        condition.lock(); defer { condition.unlock() }
        return buffer.count >= highWaterBytes
    }

    // MARK: - Demux loop

    private func startDemuxThread() {
        let thread = Thread { [weak self] in self?.runDemuxLoop() }
        thread.name = "com.tstream.ffdemux"
        // Demuxing feeds a real-time renderer, so keep it above the default band.
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    private func runDemuxLoop() {
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let demuxer = cff_demux_create({ opaque, buf, size in
            guard let opaque, let buf else { return -1 }
            let me = Unmanaged<FFStreamDemuxer>.fromOpaque(opaque).takeUnretainedValue()
            return me.readBytes(into: buf, size: size)
        }, opaque) else {
            report(.demux("could not create the libavformat reader"))
            return
        }
        self.demuxer = demuxer

        guard cff_demux_open(demuxer) == 0 else {
            // A stop during the probe unwinds through here; that isn't a failure.
            if !isStopped { report(.demux("could not read the container")) }
            return
        }

        var info = CFFStreamInfo()
        guard cff_demux_stream_info(demuxer, &info) == 0 else {
            if !isStopped { report(.demux("the container has no stream we can play")) }
            return
        }
        announce(info)

        var packet = CFFPacket()
        while !isStopped {
            let status = cff_demux_next_packet(demuxer, &packet)
            if status == 0 { break }                       // end of stream
            if status < 0 {
                if !isStopped { report(.demux("the container ended unexpectedly")) }
                return
            }
            emit(packet)
        }
    }

    private var isStopped: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopped
    }

    /// Called from libavformat on the demux thread. Blocks until there are bytes,
    /// the stream ends, or we are torn down.
    private func readBytes(into destination: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        condition.lock()
        while buffer.isEmpty && !finished && !stopped {
            condition.wait()
        }
        defer { condition.unlock() }

        guard !stopped else { return 0 }
        guard !buffer.isEmpty else { return 0 }        // finished and drained

        let count = min(Int(size), buffer.count)
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            destination.update(from: base.assumingMemoryBound(to: UInt8.self), count: count)
        }
        buffer.removeFirst(count)
        return Int32(count)
    }

    // MARK: - Output

    private func announce(_ info: CFFStreamInfo) {
        if info.has_video != 0, let codec = Self.videoCodec(info.video_codec) {
            let extradata = Self.data(info.video_extradata, info.video_extradata_size)
            videoCodecForPackets = codec
            output?.demuxerDidParseVideoFormat(codec, extradata: extradata)
            TStreamDiagnostics.log(
                "ffdemux: video \(codec) \(info.video_width)x\(info.video_height), "
                + "\(extradata?.count ?? 0) bytes of extradata")
        }

        guard info.has_audio != 0 else { return }

        if Self.needsDecoding(info.audio_codec) {
            announceDecodedAudio(info)
            return
        }

        guard let format = Self.audioFormat(info) else {
            TStreamDiagnostics.log("ffdemux: audio codec \(info.audio_codec.rawValue) not supported, playing video only")
            return
        }
        let config = format.decoderConfig.map { String(format: "%02x", $0) }.joined()
        let described = AudioSpecificConfig(parsing: format.decoderConfig)
            .map { "object type \($0.objectType), \($0.sampleRate) Hz, \($0.channels) ch" }
            ?? "not understood"
        TStreamDiagnostics.log("""
            ffdemux: audio \(format.codec) \(format.sampleRate) Hz, \(format.channels) ch, \
            config \(config.isEmpty ? "none" : config) (\(described))
            """)

        output?.demuxerDidParseAudioFormat(format)
    }

    /// Sets up decoding for Vorbis or Opus and reports the PCM the player will
    /// actually receive. The rate and channel count are taken from the decoder
    /// once it is open, since that is the authority on what it produces.
    private func announceDecodedAudio(_ info: CFFStreamInfo) {
        let extradata = Self.data(info.audio_extradata, info.audio_extradata_size)
        guard let decoder = TStreamFFAudioDecoder(codec: info.audio_codec,
                                                  sampleRate: Int(info.audio_sample_rate),
                                                  channels: Int(info.audio_channels),
                                                  extradata: extradata) else {
            TStreamDiagnostics.log("ffdemux: could not open the audio decoder, playing video only")
            return
        }
        audioDecoder = decoder
        let format = AudioFormat(codec: .pcm,
                                 sampleRate: decoder.sampleRate,
                                 channels: decoder.channels,
                                 samplesPerFrame: 1,
                                 decoderConfig: Data())
        output?.demuxerDidParseAudioFormat(format)
        TStreamDiagnostics.log(
            "ffdemux: audio decoded to PCM, \(decoder.sampleRate) Hz, \(decoder.channels) ch")
    }

    private func emit(_ packet: CFFPacket) {
        guard packet.size > 0, let bytes = packet.data else { return }
        let data = Data(bytes: bytes, count: Int(packet.size))
        // A packet without a PTS can't be scheduled against the clock.
        // Int64.min is the shim's CFF_NOPTS, which is also FFmpeg's AV_NOPTS_VALUE.
        guard packet.pts != Int64.min else { return }
        let pts = UInt64(max(0, packet.pts))
        let dts = packet.dts == Int64.min ? pts : UInt64(max(0, packet.dts))

        if packet.is_video != 0 {
            guard let codec = videoCodecForPackets else { return }
            output?.demuxerDidProduceVideo(data, codec: codec, pts: pts, dts: dts)
        } else if let audioDecoder {
            for block in audioDecoder.decode(data, pts: pts) {
                output?.demuxerDidProduceAudio(
                    AccessUnit(data: block.data, pts: block.pts, dts: block.pts, isKeyframe: true))
            }
        } else {
            output?.demuxerDidProduceAudio(
                AccessUnit(data: data, pts: pts, dts: dts, isKeyframe: true))
        }
    }

    private var videoCodecForPackets: VideoCodec?
    /// Set only for codecs Core Audio cannot take, in which case audio packets
    /// are decoded here and the player receives PCM.
    private var audioDecoder: TStreamFFAudioDecoder?

    private func report(_ error: TStreamError) {
        output?.demuxerDidFail(error)
    }

    // MARK: - Mapping

    private static func data(_ pointer: UnsafePointer<UInt8>?, _ size: Int32) -> Data? {
        guard let pointer, size > 0 else { return nil }
        return Data(bytes: pointer, count: Int(size))
    }

    private static func videoCodec(_ codec: CFFCodec) -> VideoCodec? {
        switch codec {
        case CFF_CODEC_H264: return .h264
        case CFF_CODEC_HEVC: return .h265
        case CFF_CODEC_MPEG2: return .mpeg2
        case CFF_CODEC_VP8: return .vp8
        default: return nil
        }
    }

    /// Codecs Core Audio can take are passed through compressed. MP2 from a
    /// container is left out: the TS path transcodes it, and feeding it raw
    /// would not match what the renderer is set up for.
    private static func audioFormat(_ info: CFFStreamInfo) -> AudioFormat? {
        let sampleRate = Int(info.audio_sample_rate)
        let channels = Int(info.audio_channels)
        guard sampleRate > 0, channels > 0 else { return nil }
        let extradata = data(info.audio_extradata, info.audio_extradata_size) ?? Data()

        switch info.audio_codec {
        case CFF_AUDIO_AAC:
            // Matroska and MP4 store the AudioSpecificConfig as extradata, which
            // is exactly the magic cookie Core Audio wants.
            guard !extradata.isEmpty else { return nil }
            return AudioFormat(codec: .aac, sampleRate: sampleRate, channels: channels,
                               samplesPerFrame: 1024, decoderConfig: extradata)
        case CFF_AUDIO_AC3:
            return AudioFormat(codec: .ac3, sampleRate: sampleRate, channels: channels,
                               samplesPerFrame: AC3.samplesPerFrame, decoderConfig: Data())
        case CFF_AUDIO_EAC3:
            return AudioFormat(codec: .eac3, sampleRate: sampleRate, channels: channels,
                               samplesPerFrame: 1536, decoderConfig: Data())
        default:
            return nil
        }
    }

    /// Codecs Core Audio cannot take get decoded here instead, and the player
    /// sees plain PCM.
    private static func needsDecoding(_ codec: CFFAudioCodec) -> Bool {
        codec == CFF_AUDIO_VORBIS || codec == CFF_AUDIO_OPUS
    }
}
