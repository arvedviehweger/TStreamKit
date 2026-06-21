import Foundation

enum VideoCodec: Sendable { case h264, h265 }
enum AudioCodec: Sendable { case aac, ac3 }

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
}

protocol TSDemuxerDelegate: AnyObject {
    func demuxer(_ demuxer: TSDemuxer, didParseVideoFormat format: VideoFormat)
    func demuxer(_ demuxer: TSDemuxer, didParseAudioFormat format: AudioFormat)
    func demuxer(_ demuxer: TSDemuxer, didProduceVideo unit: AccessUnit)
    func demuxer(_ demuxer: TSDemuxer, didProduceAudio unit: AccessUnit)
    func demuxer(_ demuxer: TSDemuxer, didFail error: TStreamError)
    /// Called once the PMT is parsed, reporting which elementary streams exist.
    func demuxer(_ demuxer: TSDemuxer, didIdentifyStreamsHasVideo hasVideo: Bool, hasAudio: Bool)
}

extension TSDemuxerDelegate {
    func demuxer(_ demuxer: TSDemuxer, didIdentifyStreamsHasVideo hasVideo: Bool, hasAudio: Bool) {}
}

/// Consumes validated `TSPacket`s, resolves PAT/PMT, reassembles PES packets,
/// and emits codec-tagged access units. Confined to the pipeline's serial
/// queue (not thread-safe on its own).
final class TSDemuxer {
    weak var delegate: TSDemuxerDelegate?

    // MARK: PSI / stream identification

    private var pmtPID: UInt16?
    private var videoPID: UInt16?
    private var audioPID: UInt16?
    private var videoCodec: VideoCodec?
    private var audioCodec: AudioCodec?

    private var didEmitVideoFormat = false
    private var videoVPS: Data?
    private var videoSPS: Data?
    private var videoPPS: Data?

    // MARK: PES reassembly buffers

    private struct PESAccumulator {
        var bytes: [UInt8] = []
        var started = false
    }
    private var videoPES = PESAccumulator()
    private var audioPES = PESAccumulator()

    func reset() {
        pmtPID = nil; videoPID = nil; audioPID = nil
        videoCodec = nil; audioCodec = nil
        didEmitVideoFormat = false
        videoVPS = nil; videoSPS = nil; videoPPS = nil
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
            accumulatePES(packet, into: &videoPES, isVideo: true)
        } else if pid == audioPID {
            accumulatePES(packet, into: &audioPES, isVideo: false)
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

        while i + 5 <= loopEnd {
            let streamType = b[i]
            let elementaryPID = (UInt16(b[i + 1] & 0x1F) << 8) | UInt16(b[i + 2])
            let esInfoLength = (Int(b[i + 3] & 0x0F) << 8) | Int(b[i + 4])

            switch streamType {
            case 0x1B where videoPID == nil:           // H.264
                videoPID = elementaryPID; videoCodec = .h264
            case 0x24 where videoPID == nil:           // H.265 / HEVC
                videoPID = elementaryPID; videoCodec = .h265
            case 0x0F where audioPID == nil:           // AAC (ADTS)
                audioPID = elementaryPID; audioCodec = .aac
            case 0x81 where audioPID == nil:           // AC-3
                audioPID = elementaryPID; audioCodec = .ac3
            default:
                break
            }
            i += 5 + esInfoLength
        }

        delegate?.demuxer(self, didIdentifyStreamsHasVideo: videoPID != nil, hasAudio: audioPID != nil)
    }

    // MARK: - PES

    private func accumulatePES(_ packet: TSPacket, into acc: inout PESAccumulator, isVideo: Bool) {
        if packet.payloadUnitStart {
            // A new PES begins — finish the previous one.
            if acc.started {
                let completed = acc.bytes
                if isVideo { completeVideoPES(completed) } else { completeAudioPES(completed) }
            }
            acc.bytes.removeAll(keepingCapacity: true)
            acc.started = true
        }
        guard acc.started else { return }
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
        switch videoCodec {
        case .h264: completeH264(elementary, header: header)
        case .h265: completeH265(elementary, header: header)
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
        delegate?.demuxer(self, didProduceVideo: AccessUnit(data: sample.data,
                                                            pts: header.pts,
                                                            dts: header.dts,
                                                            isKeyframe: sample.isKeyframe))
    }

    private func emitH264FormatIfReady() {
        guard !didEmitVideoFormat, let sps = videoSPS, let pps = videoPPS else { return }
        let dims = H264.parseSPS([UInt8](sps)[...]) ?? H264.Dimensions(width: 1280, height: 720)
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

    private func completeAudioPES(_ bytes: [UInt8]) {
        guard let header = parsePESHeader(bytes) else { return }
        let elementary = Array(bytes[header.payloadOffset...])
        switch audioCodec {
        case .aac: completeAAC(elementary, header: header)
        case .ac3: completeAC3(elementary, header: header)
        case .none: break
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
