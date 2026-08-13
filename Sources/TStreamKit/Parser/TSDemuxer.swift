import Foundation

enum VideoCodec: Sendable { case h264, h265, mpeg2, vp8 }
enum AudioCodec: Sendable { case aac, ac3, eac3, mp2 }
enum VideoSyncType: Sendable { case none, idr, nonIDRIntra }

/// Decoder configuration for the video elementary stream.
struct VideoFormat: Sendable {
    let codec: VideoCodec
    let vps: Data           // empty for H.264
    let sps: Data
    let pps: Data
    let width: Int
    let height: Int
    /// HLS `CODECS` attribute value (e.g. `avc1.640028` or `hvc1.1.6.L93.B0`).
    let codecParameters: String
    /// HEVC-only fields needed for the `hvcC` record; `nil` for H.264.
    let hevc: HEVC.ParameterSetInfo?
}

/// Decoder configuration for the audio elementary stream.
struct AudioFormat: Sendable {
    let codec: AudioCodec
    let sampleRate: Int
    let channels: Int
    /// PCM samples represented by one access unit (1024 AAC, 1536 AC-3).
    let samplesPerFrame: Int
    /// Codec decoder config: AudioSpecificConfig for AAC, `dac3` payload for AC-3.
    let decoderConfig: Data
}

/// One decodable unit ready for muxing.
struct AccessUnit: Sendable {
    let data: Data          // AVCC for video, raw AAC frame for audio
    let pts: UInt64         // 90 kHz clock
    let dts: UInt64         // 90 kHz clock
    let isKeyframe: Bool
    let startsSegment: Bool
    let syncType: VideoSyncType

    init(data: Data,
         pts: UInt64,
         dts: UInt64,
         isKeyframe: Bool,
         startsSegment: Bool? = nil,
         syncType: VideoSyncType? = nil) {
        let resolvedSyncType = syncType ?? (isKeyframe ? .idr : .none)
        self.data = data
        self.pts = pts
        self.dts = dts
        self.isKeyframe = resolvedSyncType != .none
        self.startsSegment = startsSegment ?? (resolvedSyncType != .none)
        self.syncType = resolvedSyncType
    }
}

protocol TSDemuxerDelegate: AnyObject {
    func demuxer(_ demuxer: TSDemuxer, didParseVideoFormat format: VideoFormat)
    func demuxer(_ demuxer: TSDemuxer, didParseAudioFormat format: AudioFormat)
    func demuxer(_ demuxer: TSDemuxer, didProduceVideo unit: AccessUnit)
    func demuxer(_ demuxer: TSDemuxer, didProduceAudio unit: AccessUnit)
    func demuxer(_ demuxer: TSDemuxer, didFail error: TStreamError)
    /// Called once the PMT is parsed, reporting which elementary streams exist.
    func demuxer(_ demuxer: TSDemuxer, didIdentifyStreamsHasVideo hasVideo: Bool, hasAudio: Bool)
    /// Raw-mode only: the unprocessed (Annex-B) video PES payload, for decoders
    /// (libavcodec) that do their own NAL/field/frame assembly.
    func demuxer(_ demuxer: TSDemuxer, didProduceRawVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64)
}

// Everything except the audio and failure callbacks is optional: a raw-video
// consumer (the player, via libavcodec) never sees parsed access units, and a
// muxing consumer never sees raw video.
extension TSDemuxerDelegate {
    func demuxer(_ demuxer: TSDemuxer, didIdentifyStreamsHasVideo hasVideo: Bool, hasAudio: Bool) {}
    func demuxer(_ demuxer: TSDemuxer, didProduceRawVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {}
    func demuxer(_ demuxer: TSDemuxer, didParseVideoFormat format: VideoFormat) {}
    func demuxer(_ demuxer: TSDemuxer, didProduceVideo unit: AccessUnit) {}
}

/// Consumes validated `TSPacket`s, resolves PAT/PMT, reassembles PES packets,
/// and emits codec-tagged access units. Confined to the pipeline's serial
/// queue (not thread-safe on its own).
final class TSDemuxer {
    weak var delegate: TSDemuxerDelegate?

    /// When true, video PES payloads are forwarded raw via `didProduceRawVideo`
    /// (for libavcodec) instead of being parsed into access units.
    var rawVideoMode = false

    // MARK: PSI / stream identification

    private var pmtPID: UInt16?
    private var videoPID: UInt16?
    private var audioPID: UInt16?
    private var videoCodec: VideoCodec?
    private var audioCodec: AudioCodec?
    /// AAC audio is LATM/LOAS-framed (PMT 0x11) rather than ADTS (0x0F).
    private var audioLATM = false

    private var didEmitVideoFormat = false
    private var videoVPS: Data?
    private var videoSPS: Data?
    private var videoPPS: Data?
    private var lastContinuity: [UInt16: UInt8] = [:]

    // H.264 field coding (PAFF). When the SPS is interlaced, each coded picture
    // is a single field; two complementary fields are combined into one frame
    // access unit before muxing. `frameMbsOnly` short-circuits this for
    // progressive streams.
    private var videoLog2MaxFrameNum = 4
    private var videoFrameMbsOnly = true
    private struct PendingField {
        let data: Data
        let pts: UInt64
        let dts: UInt64
        let syncType: VideoSyncType
        let frameNum: UInt32
        let bottomField: Bool
    }
    private var pendingField: PendingField?

    // MARK: PES reassembly buffers

    private struct PESAccumulator {
        var bytes: [UInt8] = []
        var started = false
    }
    private var videoPES = PESAccumulator()
    private var audioPES = PESAccumulator()

    func reset() {
        pmtPID = nil; videoPID = nil; audioPID = nil
        videoCodec = nil; audioCodec = nil; audioLATM = false
        latmParser.reset()
        didEmitVideoFormat = false
        videoVPS = nil; videoSPS = nil; videoPPS = nil
        lastContinuity.removeAll()
        videoLog2MaxFrameNum = 4
        videoFrameMbsOnly = true
        pendingField = nil
        videoPES = PESAccumulator()
        audioPES = PESAccumulator()
    }

    func consume(_ packet: TSPacket) {
        let pid = packet.pid
        if pid == 0x0000 {
            parsePAT(packet)
        } else if pid == pmtPID {
            parsePMT(packet)
        } else if pid == videoPID {
            accumulatePES(packet, into: &videoPES, isVideo: true, continuityOK: validateContinuity(packet))
        } else if pid == audioPID {
            accumulatePES(packet, into: &audioPES, isVideo: false, continuityOK: validateContinuity(packet))
        }
    }

    /// Flush any buffered PES at end of stream so the final samples are emitted.
    func flush() {
        if videoPES.started { completeVideoPES(videoPES.bytes); videoPES = PESAccumulator() }
        if audioPES.started { completeAudioPES(audioPES.bytes); audioPES = PESAccumulator() }
    }

    // MARK: - PSI

    /// Extracts a PSI section payload, honoring the leading `pointer_field`.
    private func sectionPayload(_ packet: TSPacket) -> ArraySlice<UInt8>? {
        guard packet.payloadUnitStart, !packet.payload.isEmpty else { return nil }
        let payload = packet.payload
        let pointer = Int(payload[payload.startIndex])
        let start = payload.index(payload.startIndex, offsetBy: 1 + pointer)
        guard start < payload.endIndex else { return nil }
        return payload[start...]
    }

    private func parsePAT(_ packet: TSPacket) {
        guard pmtPID == nil, let section = sectionPayload(packet) else { return }
        let b = Array(section)
        guard b.count >= 8, b[0] == 0x00 else { return } // table_id == PAT

        let sectionLength = (Int(b[1] & 0x0F) << 8) | Int(b[2])
        // Program loop starts at byte 8, last 4 bytes are CRC32.
        let loopEnd = min(3 + sectionLength - 4, b.count)
        var i = 8
        while i + 4 <= loopEnd {
            let programNumber = (UInt16(b[i]) << 8) | UInt16(b[i + 1])
            let pid = (UInt16(b[i + 2] & 0x1F) << 8) | UInt16(b[i + 3])
            if programNumber != 0 {       // 0 == network PID
                pmtPID = pid
                break
            }
            i += 4
        }
    }

    private func parsePMT(_ packet: TSPacket) {
        guard videoPID == nil, audioPID == nil, let section = sectionPayload(packet) else { return }
        let b = Array(section)
        guard b.count >= 12, b[0] == 0x02 else { return } // table_id == PMT

        let sectionLength = (Int(b[1] & 0x0F) << 8) | Int(b[2])
        let programInfoLength = (Int(b[10] & 0x0F) << 8) | Int(b[11])
        var i = 12 + programInfoLength
        let loopEnd = min(3 + sectionLength - 4, b.count)

        // Audio selection is preference-ranked, not first-wins: DVB channels
        // (e.g. ZDF HD) carry a Dolby AC-3 track alongside an MPEG stereo track,
        // and we want the AC-3 one. Higher rank wins; ties keep the first seen.
        var audioRank = -1

        while i + 5 <= loopEnd {
            let streamType = b[i]
            let elementaryPID = (UInt16(b[i + 1] & 0x1F) << 8) | UInt16(b[i + 2])
            let esInfoLength = (Int(b[i + 3] & 0x0F) << 8) | Int(b[i + 4])
            let descStart = i + 5
            let descriptors = b[descStart..<min(descStart + esInfoLength, loopEnd)]

            if videoPID == nil {
                switch streamType {
                case 0x02: videoPID = elementaryPID; videoCodec = .mpeg2  // MPEG-2 video
                case 0x1B: videoPID = elementaryPID; videoCodec = .h264   // H.264
                case 0x24: videoPID = elementaryPID; videoCodec = .h265   // H.265 / HEVC
                default: break
                }
            }

            if let candidate = Self.classifyAudio(streamType: streamType, descriptors: descriptors),
               candidate.rank > audioRank {
                audioPID = elementaryPID
                audioCodec = candidate.codec
                audioLATM = candidate.latm
                audioRank = candidate.rank
            }

            i = descStart + esInfoLength
        }

        delegate?.demuxer(self, didIdentifyStreamsHasVideo: videoPID != nil, hasAudio: audioPID != nil)
    }

    /// Classifies a PMT elementary stream as an audio candidate with a selection
    /// rank (higher wins). Dolby outranks AAC/MP2 and E-AC-3 outranks AC-3, so the
    /// premium track is chosen when a channel offers several. `latm` marks AAC
    /// that is LOAS/LATM-framed (0x11) rather than ADTS (0x0F). Returns `nil` for
    /// non-audio streams.
    private static func classifyAudio(streamType: UInt8, descriptors: ArraySlice<UInt8>)
        -> (codec: AudioCodec, latm: Bool, rank: Int)? {
        switch streamType {
        case 0x0F: return (.aac, false, 1)             // AAC (ADTS)
        case 0x11: return (.aac, true, 1)              // AAC (LATM/LOAS)
        case 0x03, 0x04: return (.mp2, false, 1)       // MPEG-1/2 audio (Layer II)
        case 0x81: return (.ac3, false, 2)             // ATSC AC-3
        case 0x87: return (.eac3, false, 3)            // ATSC E-AC-3
        case 0x06:                                     // DVB private data — Dolby if a descriptor says so
            if dvbHasDescriptor(0x7A, descriptors) { return (.eac3, false, 3) } // DVB E-AC-3
            return isDVBAC3(descriptors) ? (.ac3, false, 2) : nil
        default: return nil
        }
    }

    /// Whether a `stream_type 0x06` private stream is AC-3, per its ES-info
    /// descriptors: a DVB AC-3 descriptor (tag `0x6A`) or a registration
    /// descriptor (tag `0x05`) carrying the `AC-3` format identifier.
    private static func isDVBAC3(_ descriptors: ArraySlice<UInt8>) -> Bool {
        if dvbHasDescriptor(0x6A, descriptors) { return true }   // DVB AC-3_descriptor
        let d = Array(descriptors)
        var j = 0
        while j + 2 <= d.count {
            let tag = d[j]
            let len = Int(d[j + 1])
            let body = j + 2
            guard body + len <= d.count else { break }
            if tag == 0x05, len >= 4,                   // registration_descriptor "AC-3"
               d[body] == 0x41, d[body + 1] == 0x43, d[body + 2] == 0x2D, d[body + 3] == 0x33 {
                return true
            }
            j = body + len
        }
        return false
    }

    /// Whether the ES-info descriptor loop contains a descriptor with `tag`.
    private static func dvbHasDescriptor(_ tag: UInt8, _ descriptors: ArraySlice<UInt8>) -> Bool {
        let d = Array(descriptors)
        var j = 0
        while j + 2 <= d.count {
            let len = Int(d[j + 1])
            guard j + 2 + len <= d.count else { break }
            if d[j] == tag { return true }
            j += 2 + len
        }
        return false
    }

    // MARK: - PES

    private func validateContinuity(_ packet: TSPacket) -> Bool {
        guard !packet.payload.isEmpty else { return true }
        defer { lastContinuity[packet.pid] = packet.continuityCounter }
        guard let previous = lastContinuity[packet.pid] else { return true }
        let expected = (previous + 1) & 0x0F
        if packet.continuityCounter == expected { return true }
        TStreamDiagnostics.log("demux: continuity gap pid=\(packet.pid) expected \(expected) got \(packet.continuityCounter)")
        return false
    }

    private func accumulatePES(_ packet: TSPacket,
                               into acc: inout PESAccumulator,
                               isVideo: Bool,
                               continuityOK: Bool) {
        let canUsePacket = continuityOK || packet.payloadUnitStart
        if !continuityOK {
            acc.bytes.removeAll(keepingCapacity: true)
            acc.started = false
        }
        if packet.payloadUnitStart {
            // A new PES begins — finish the previous one.
            if continuityOK, acc.started {
                let completed = acc.bytes
                if isVideo { completeVideoPES(completed) } else { completeAudioPES(completed) }
            }
            acc.bytes.removeAll(keepingCapacity: true)
            acc.started = true
        }
        guard canUsePacket, acc.started else { return }
        acc.bytes.append(contentsOf: packet.payload)
    }

    /// Parses the PES header, returning timestamps and the offset where the
    /// elementary payload begins.
    private func parsePESHeader(_ b: [UInt8]) -> (pts: UInt64, dts: UInt64, payloadOffset: Int)? {
        guard b.count >= 9, b[0] == 0x00, b[1] == 0x00, b[2] == 0x01 else { return nil }
        let ptsDtsFlags = (b[7] & 0xC0) >> 6
        let headerDataLength = Int(b[8])
        let payloadOffset = 9 + headerDataLength
        guard payloadOffset <= b.count else { return nil }

        var pts: UInt64 = 0
        var dts: UInt64 = 0
        if ptsDtsFlags == 0b10, b.count >= 14 {
            pts = readTimestamp(b, 9)
            dts = pts
        } else if ptsDtsFlags == 0b11, b.count >= 19 {
            pts = readTimestamp(b, 9)
            dts = readTimestamp(b, 14)
        }
        return (pts, dts, payloadOffset)
    }

    private func readTimestamp(_ b: [UInt8], _ o: Int) -> UInt64 {
        let p0 = UInt64(b[o]), p1 = UInt64(b[o + 1]), p2 = UInt64(b[o + 2])
        let p3 = UInt64(b[o + 3]), p4 = UInt64(b[o + 4])
        var ts = ((p0 >> 1) & 0x07) << 30
        ts |= p1 << 22
        ts |= ((p2 >> 1) & 0x7F) << 15
        ts |= p3 << 7
        ts |= (p4 >> 1) & 0x7F
        return ts
    }

    private func completeVideoPES(_ bytes: [UInt8]) {
        guard let header = parsePESHeader(bytes) else { return }
        let elementary = Array(bytes[header.payloadOffset...])
        if rawVideoMode, let codec = videoCodec {
            delegate?.demuxer(self, didProduceRawVideo: Data(elementary), codec: codec,
                              pts: header.pts, dts: header.dts)
            return
        }
        switch videoCodec {
        case .h264: completeH264(elementary, header: header)
        case .h265: completeH265(elementary, header: header)
        case .mpeg2: break   // MPEG-2 is decode-only (raw-video path); not muxed to fMP4
        case .vp8: break     // only ever arrives via a container, never in TS
        case .none: break
        }
    }

    private func completeH264(_ elementary: [UInt8], header: (pts: UInt64, dts: UInt64, payloadOffset: Int)) {
        let nals = H264.splitNALUnits(elementary)
        guard !nals.isEmpty else { return }

        // Capture parameter sets and emit the video format once.
        for nal in nals {
            if nal.type == H264.NALType.sps.rawValue, videoSPS == nil {
                videoSPS = Data(nal.bytes)
            } else if nal.type == H264.NALType.pps.rawValue, videoPPS == nil {
                videoPPS = Data(nal.bytes)
            }
        }
        emitH264FormatIfReady()

        let sample = H264.avccSample(from: nals)
        guard !sample.data.isEmpty, didEmitVideoFormat else { return }

        // Interlaced (PAFF) streams code each picture as a single field; pair
        // complementary top/bottom fields into one frame before muxing. A
        // frame-only SPS, or a frame picture inside a mixed stream, is emitted
        // straight through.
        if !videoFrameMbsOnly,
           let field = H264.fieldInfo(fromFirstSlice: nals, log2MaxFrameNum: videoLog2MaxFrameNum),
           field.fieldPicture {
            handleFieldPicture(sample, header: header, field: field)
            return
        }

        discardPendingField()
        emitVideoFrame(data: sample.data, pts: header.pts, dts: header.dts, syncType: sample.syncType)
    }

    /// Buffers a field picture and emits a combined frame once its complement
    /// (same `frame_num`, opposite parity) arrives. A non-matching field flushes
    /// the orphan (dropped) and starts a fresh pair — this self-corrects within
    /// one field when playback starts mid-pair.
    private func handleFieldPicture(_ sample: (data: Data, isKeyframe: Bool, startsSegment: Bool, syncType: VideoSyncType),
                                    header: (pts: UInt64, dts: UInt64, payloadOffset: Int),
                                    field: H264.FieldInfo) {
        if let pending = pendingField,
           pending.frameNum == field.frameNum,
           pending.bottomField != field.bottomField {
            var data = pending.data
            data.append(sample.data)
            // The frame is decoded/displayed at its earlier field's times; its
            // sync status comes from whichever field carries the intra slice.
            let syncType = pending.syncType != .none ? pending.syncType : sample.syncType
            pendingField = nil
            emitVideoFrame(data: data,
                           pts: min(pending.pts, header.pts),
                           dts: min(pending.dts, header.dts),
                           syncType: syncType)
            return
        }

        discardPendingField()
        pendingField = PendingField(data: sample.data,
                                    pts: header.pts,
                                    dts: header.dts,
                                    syncType: sample.syncType,
                                    frameNum: field.frameNum,
                                    bottomField: field.bottomField)
    }

    /// Drops an unpaired field. Complementary fields are adjacent in a gap-free
    /// stream, so this only fires at start-up or after a (logged) continuity gap.
    private func discardPendingField() {
        pendingField = nil
    }

    private func emitVideoFrame(data: Data, pts: UInt64, dts: UInt64, syncType: VideoSyncType) {
        delegate?.demuxer(self, didProduceVideo: AccessUnit(data: data,
                                                            pts: pts,
                                                            dts: dts,
                                                            isKeyframe: syncType != .none,
                                                            startsSegment: syncType != .none,
                                                            syncType: syncType))
    }

    private func emitH264FormatIfReady() {
        guard !didEmitVideoFormat, let sps = videoSPS, let pps = videoPPS else { return }
        let info = H264.parseSPSInfo([UInt8](sps)[...])
        if let info {
            videoLog2MaxFrameNum = info.log2MaxFrameNum
            videoFrameMbsOnly = info.frameMbsOnly
        }
        let dims = info.map { H264.Dimensions(width: $0.width, height: $0.height) }
            ?? H264.Dimensions(width: 1280, height: 720)
        let b = [UInt8](sps)
        let params = b.count >= 4
            ? String(format: "avc1.%02x%02x%02x", b[1], b[2], b[3])
            : "avc1.640028"
        didEmitVideoFormat = true
        delegate?.demuxer(self, didParseVideoFormat: VideoFormat(codec: .h264,
                                                                vps: Data(),
                                                                sps: sps,
                                                                pps: pps,
                                                                width: dims.width,
                                                                height: dims.height,
                                                                codecParameters: params,
                                                                hevc: nil))
    }

    private func completeH265(_ elementary: [UInt8], header: (pts: UInt64, dts: UInt64, payloadOffset: Int)) {
        let nals = HEVC.splitNALUnits(elementary)
        guard !nals.isEmpty else { return }

        for nal in nals {
            switch nal.type {
            case HEVC.NALType.vps where videoVPS == nil: videoVPS = Data(nal.bytes)
            case HEVC.NALType.sps where videoSPS == nil: videoSPS = Data(nal.bytes)
            case HEVC.NALType.pps where videoPPS == nil: videoPPS = Data(nal.bytes)
            default: break
            }
        }
        emitH265FormatIfReady()

        let sample = HEVC.sample(from: nals)
        guard !sample.data.isEmpty, didEmitVideoFormat else { return }
        delegate?.demuxer(self, didProduceVideo: AccessUnit(data: sample.data,
                                                            pts: header.pts,
                                                            dts: header.dts,
                                                            isKeyframe: sample.isKeyframe))
    }

    private func emitH265FormatIfReady() {
        guard !didEmitVideoFormat,
              let vps = videoVPS, let sps = videoSPS, let pps = videoPPS,
              let info = HEVC.parseSPS([UInt8](sps)[...]) else { return }
        didEmitVideoFormat = true
        delegate?.demuxer(self, didParseVideoFormat:
            VideoFormat(codec: .h265,
                        vps: vps,
                        sps: sps,
                        pps: pps,
                        width: info.dimensions.width,
                        height: info.dimensions.height,
                        codecParameters: HEVC.codecParameters(generalProfileTierLevel: info.generalProfileTierLevel),
                        hevc: info))
    }

    private var didEmitAudioFormat = false

    /// Transcodes MP2 → AAC, surfacing the result through the normal audio
    /// delegate callbacks so the muxer only ever sees AAC.
    private lazy var mp2Transcoder: MP2Transcoder = {
        let transcoder = MP2Transcoder()
        transcoder.onFormat = { [weak self] format in
            guard let self, !self.didEmitAudioFormat else { return }
            self.didEmitAudioFormat = true
            self.delegate?.demuxer(self, didParseAudioFormat: format)
        }
        transcoder.onAAC = { [weak self] data, pts in
            guard let self else { return }
            self.delegate?.demuxer(self, didProduceAudio: AccessUnit(data: data, pts: pts, dts: pts, isKeyframe: true))
        }
        return transcoder
    }()

    private let latmParser = LATMParser()

    private func completeAudioPES(_ bytes: [UInt8]) {
        guard let header = parsePESHeader(bytes) else { return }
        let elementary = Array(bytes[header.payloadOffset...])
        switch audioCodec {
        case .aac: audioLATM ? completeAACLATM(elementary, header: header)
                             : completeAAC(elementary, header: header)
        case .ac3: completeAC3(elementary, header: header)
        case .eac3: completeEAC3(elementary, header: header)
        case .mp2: mp2Transcoder.consume(elementary, pts: header.pts)
        case .none: break
        }
    }

    /// LATM/LOAS-framed AAC (DVB 0x11): de-multiplex to raw AAC, then surface it
    /// through the same AAC format/access-unit path as ADTS.
    private func completeAACLATM(_ elementary: [UInt8], header: (pts: UInt64, dts: UInt64, payloadOffset: Int)) {
        let frames = latmParser.parse(elementary)
        guard let cfg = latmParser.config else { return }

        if !didEmitAudioFormat {
            didEmitAudioFormat = true
            delegate?.demuxer(self, didParseAudioFormat: AudioFormat(codec: .aac,
                                                                    sampleRate: cfg.sampleRate,
                                                                    channels: cfg.channels,
                                                                    samplesPerFrame: 1024,
                                                                    decoderConfig: cfg.audioSpecificConfig))
        }

        // Each AAC frame is 1024 samples; spread PTS across the frames in the PES.
        let ticksPerFrame = UInt64(1024 * 90000 / max(cfg.sampleRate, 1))
        for (index, frame) in frames.enumerated() {
            let pts = header.pts + UInt64(index) * ticksPerFrame
            delegate?.demuxer(self, didProduceAudio: AccessUnit(data: Data(frame),
                                                               pts: pts,
                                                               dts: pts,
                                                               isKeyframe: true))
        }
    }

    private func completeAAC(_ elementary: [UInt8], header: (pts: UInt64, dts: UInt64, payloadOffset: Int)) {
        let frames = ADTS.frames(in: elementary)
        guard !frames.isEmpty else { return }

        if !didEmitAudioFormat {
            let cfg = ADTS.config(from: frames[0])
            didEmitAudioFormat = true
            delegate?.demuxer(self, didParseAudioFormat: AudioFormat(codec: .aac,
                                                                    sampleRate: cfg.sampleRate,
                                                                    channels: cfg.channels,
                                                                    samplesPerFrame: 1024,
                                                                    decoderConfig: cfg.audioSpecificConfig))
        }

        // Each AAC frame is 1024 samples; distribute PTS across frames in the PES.
        let sampleRate = ADTS.sampleRates[safe: frames[0].sampleRateIndex] ?? 44100
        let ticksPerFrame = UInt64(1024 * 90000 / max(sampleRate, 1))
        for (index, frame) in frames.enumerated() {
            let pts = header.pts + UInt64(index) * ticksPerFrame
            delegate?.demuxer(self, didProduceAudio: AccessUnit(data: Data(frame.raw),
                                                               pts: pts,
                                                               dts: pts,
                                                               isKeyframe: true))
        }
    }

    private func completeAC3(_ elementary: [UInt8], header: (pts: UInt64, dts: UInt64, payloadOffset: Int)) {
        let frames = AC3.frames(in: elementary)
        guard !frames.isEmpty, let cfg = AC3.config(from: frames[0].raw) else { return }

        if !didEmitAudioFormat {
            didEmitAudioFormat = true
            delegate?.demuxer(self, didParseAudioFormat: AudioFormat(codec: .ac3,
                                                                    sampleRate: cfg.sampleRate,
                                                                    channels: cfg.channels,
                                                                    samplesPerFrame: AC3.samplesPerFrame,
                                                                    decoderConfig: cfg.dac3))
        }

        // Each AC-3 sync frame is 1536 samples; distribute PTS across the PES.
        let ticksPerFrame = UInt64(AC3.samplesPerFrame * 90000 / max(cfg.sampleRate, 1))
        for (index, frame) in frames.enumerated() {
            let pts = header.pts + UInt64(index) * ticksPerFrame
            delegate?.demuxer(self, didProduceAudio: AccessUnit(data: Data(frame.raw),
                                                               pts: pts,
                                                               dts: pts,
                                                               isKeyframe: true))
        }
    }

    private func completeEAC3(_ elementary: [UInt8], header: (pts: UInt64, dts: UInt64, payloadOffset: Int)) {
        let frames = EAC3.frames(in: elementary)
        guard !frames.isEmpty, let cfg = EAC3.config(from: frames[0].raw) else { return }

        if !didEmitAudioFormat {
            didEmitAudioFormat = true
            // E-AC-3 passes through to the system decoder; no magic cookie needed.
            delegate?.demuxer(self, didParseAudioFormat: AudioFormat(codec: .eac3,
                                                                    sampleRate: cfg.sampleRate,
                                                                    channels: cfg.channels,
                                                                    samplesPerFrame: cfg.samplesPerFrame,
                                                                    decoderConfig: Data()))
        }

        let ticksPerFrame = UInt64(cfg.samplesPerFrame * 90000 / max(cfg.sampleRate, 1))
        for (index, frame) in frames.enumerated() {
            let pts = header.pts + UInt64(index) * ticksPerFrame
            delegate?.demuxer(self, didProduceAudio: AccessUnit(data: Data(frame.raw),
                                                               pts: pts,
                                                               dts: pts,
                                                               isKeyframe: true))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
