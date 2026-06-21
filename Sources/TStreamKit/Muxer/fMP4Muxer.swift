import Foundation

/// Builds a fragmented-MP4 byte stream from demuxed access units: a single
/// initialization segment (`ftyp` + `moov`) followed by `moof` + `mdat`
/// fragments. Confined to the pipeline's serial queue.
final class FMP4Muxer {
    private let video: VideoFormat
    private let audio: AudioFormat?
    private let videoTimescale: UInt32 = 90_000
    private let audioTimescale: UInt32

    private let videoTrackID: UInt32 = 1
    private let audioTrackID: UInt32 = 2

    private var sequenceNumber: UInt32 = 1
    private var videoPending: [AccessUnit] = []
    private var audioPending: [AccessUnit] = []

    /// First media timestamp seen (90 kHz). All fragment decode times are
    /// rebased against this so the presentation timeline starts near zero,
    /// avoiding a black gap at the start (MPEG-TS PTS/DTS rarely start at 0).
    private var baseMediaTime90k: UInt64?

    /// Called for every completed media segment, with its duration in seconds.
    var onSegment: ((Data, Double) -> Void)?

    init(video: VideoFormat, audio: AudioFormat?) {
        self.video = video
        self.audio = audio
        self.audioTimescale = UInt32(audio?.sampleRate ?? 48_000)
    }

    // MARK: - Input

    func addVideo(_ unit: AccessUnit) {
        if baseMediaTime90k == nil { baseMediaTime90k = unit.dts }
        if unit.isKeyframe, !videoPending.isEmpty {
            flush()
        }
        videoPending.append(unit)
    }

    func addAudio(_ unit: AccessUnit) {
        if baseMediaTime90k == nil { baseMediaTime90k = unit.pts }
        audioPending.append(unit)
    }

    /// Rebases a 90 kHz timestamp against the first one seen (clamped at zero).
    private func rebased(_ time90k: UInt64) -> UInt64 {
        let base = baseMediaTime90k ?? time90k
        return time90k >= base ? time90k - base : 0
    }

    /// Emit whatever is buffered as a final fragment.
    func finish() {
        if !videoPending.isEmpty || !audioPending.isEmpty { flush() }
    }

    // MARK: - Fragment assembly

    private struct Sample {
        let data: Data
        let duration: UInt32
        let flags: UInt32
    }

    private func flush() {
        let videoSamples = makeVideoSamples(videoPending)
        let audioSamples = makeAudioSamples(audioPending)
        let firstVideoDTS = videoPending.first?.dts ?? 0
        let firstAudioPTS = audioPending.first?.pts ?? 0
        videoPending.removeAll(keepingCapacity: true)
        audioPending.removeAll(keepingCapacity: true)

        guard !videoSamples.isEmpty || !audioSamples.isEmpty else { return }

        let fragment = buildFragment(videoSamples: videoSamples,
                                     audioSamples: audioSamples,
                                     videoBaseDecodeTime: rebased(firstVideoDTS),
                                     audioBasePTS: rebased(firstAudioPTS))
        sequenceNumber += 1

        let videoTicks = videoSamples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
        let duration: Double
        if videoTicks > 0 {
            duration = Double(videoTicks) / Double(videoTimescale)
        } else {
            duration = Double(audioSamples.count) * Double(audio?.samplesPerFrame ?? 1024) / Double(audioTimescale)
        }
        onSegment?(fragment, duration)
    }

    private func makeVideoSamples(_ units: [AccessUnit]) -> [Sample] {
        guard !units.isEmpty else { return [] }
        var samples: [Sample] = []
        let defaultDuration: UInt32 = 3000 // ~30 fps at 90 kHz, fallback
        for (i, unit) in units.enumerated() {
            let duration: UInt32
            if i + 1 < units.count {
                let delta = Int64(units[i + 1].dts) - Int64(unit.dts)
                duration = delta > 0 ? UInt32(delta) : defaultDuration
            } else {
                duration = samples.last?.duration ?? defaultDuration
            }
            let flags: UInt32 = unit.isKeyframe ? 0x0200_0000 : 0x0101_0000
            samples.append(Sample(data: unit.data, duration: duration, flags: flags))
        }
        return samples
    }

    private func makeAudioSamples(_ units: [AccessUnit]) -> [Sample] {
        let duration = UInt32(audio?.samplesPerFrame ?? 1024)
        return units.map { Sample(data: $0.data, duration: duration, flags: 0x0200_0000) }
    }

    // MARK: - Initialization segment

    func initializationSegment() -> Data {
        MP4Box.concat([ftyp(), moov()])
    }

    private func ftyp() -> Data {
        var w = ByteWriter()
        w.fourCC("iso5")        // major brand
        w.u32(0x0000_0200)      // minor version
        w.fourCC("iso5"); w.fourCC("iso6"); w.fourCC("mp41")
        w.fourCC(video.codec == .h265 ? "hvc1" : "avc1")
        return MP4Box.box("ftyp", w.data)
    }

    private func moov() -> Data {
        var traks = [videoTrak()]
        if audio != nil { traks.append(audioTrak()) }
        let body = MP4Box.concat([mvhd()] + traks + [mvex()])
        return MP4Box.box("moov", body)
    }

    private func mvhd() -> Data {
        var w = ByteWriter()
        w.u32(0); w.u32(0)              // creation / modification time
        w.u32(1000)                     // timescale
        w.u32(0)                        // duration (0 == unknown for fMP4)
        w.u32(0x0001_0000)              // rate 1.0
        w.u16(0x0100)                   // volume 1.0
        w.u16(0)                        // reserved
        w.u32(0); w.u32(0)              // reserved
        for v in unityMatrix { w.u32(v) }
        for _ in 0..<6 { w.u32(0) }     // pre_defined
        w.u32(3)                        // next_track_ID
        return MP4Box.fullBox("mvhd", version: 0, flags: 0, w.data)
    }

    private func mvex() -> Data {
        var trexes = [trex(trackID: videoTrackID)]
        if audio != nil { trexes.append(trex(trackID: audioTrackID)) }
        return MP4Box.box("mvex", MP4Box.concat(trexes))
    }

    private func trex(trackID: UInt32) -> Data {
        var w = ByteWriter()
        w.u32(trackID)
        w.u32(1)    // default_sample_description_index
        w.u32(0)    // default_sample_duration
        w.u32(0)    // default_sample_size
        w.u32(0)    // default_sample_flags
        return MP4Box.fullBox("trex", version: 0, flags: 0, w.data)
    }

    // MARK: Video track

    private func videoTrak() -> Data {
        MP4Box.box("trak", MP4Box.concat([
            tkhd(trackID: videoTrackID, width: video.width, height: video.height, isAudio: false),
            MP4Box.box("mdia", MP4Box.concat([
                mdhd(timescale: videoTimescale),
                hdlr(handlerType: "vide", name: "VideoHandler"),
                MP4Box.box("minf", MP4Box.concat([
                    vmhd(), dinf(),
                    MP4Box.box("stbl", MP4Box.concat([
                        MP4Box.box("stsd", stsdBody(sampleEntry: videoSampleEntry())),
                        emptyFullBox("stts"), emptyFullBox("stsc"),
                        stsz(), emptyFullBox("stco"),
                    ])),
                ])),
            ])),
        ]))
    }

    /// `avc1`/`avcC` for H.264, `hvc1`/`hvcC` for HEVC.
    private func videoSampleEntry() -> Data {
        let (type, config) = video.codec == .h265 ? ("hvc1", hvcC()) : ("avc1", avcC())
        var w = ByteWriter()
        for _ in 0..<6 { w.u8(0) }       // reserved
        w.u16(1)                          // data_reference_index
        w.u16(0); w.u16(0)                // pre_defined / reserved
        for _ in 0..<3 { w.u32(0) }       // pre_defined
        w.u16(UInt16(video.width)); w.u16(UInt16(video.height))
        w.u32(0x0048_0000); w.u32(0x0048_0000) // resolutions 72 dpi
        w.u32(0)                          // reserved
        w.u16(1)                          // frame_count
        w.bytes(compressorName(""))       // 32-byte compressor name
        w.u16(0x0018)                     // depth
        w.i16(-1)                         // pre_defined
        w.append(config)
        return MP4Box.box(type, w.data)
    }

    private func avcC() -> Data {
        let sps = [UInt8](video.sps)
        let pps = [UInt8](video.pps)
        var w = ByteWriter()
        w.u8(1)                                   // configurationVersion
        w.u8(sps.count > 1 ? sps[1] : 0)          // AVCProfileIndication
        w.u8(sps.count > 2 ? sps[2] : 0)          // profile_compatibility
        w.u8(sps.count > 3 ? sps[3] : 0)          // AVCLevelIndication
        w.u8(0xFF)                                // 6 bits reserved + lengthSizeMinusOne=3
        w.u8(0xE1)                                // 3 bits reserved + numOfSPS=1
        w.u16(UInt16(sps.count)); w.bytes(sps)
        w.u8(1)                                   // numOfPPS
        w.u16(UInt16(pps.count)); w.bytes(pps)
        return MP4Box.box("avcC", w.data)
    }

    /// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15) with VPS/SPS/PPS arrays.
    private func hvcC() -> Data {
        guard let info = video.hevc else { return Data() }
        let vps = [UInt8](video.vps)
        let sps = [UInt8](video.sps)
        let pps = [UInt8](video.pps)

        var w = ByteWriter()
        w.u8(1)                                   // configurationVersion
        w.bytes(info.generalProfileTierLevel)     // profile_space … level_idc (12 bytes)
        w.u16(0xF000)                             // reserved | min_spatial_segmentation_idc=0
        w.u8(0xFC)                                // reserved | parallelismType=0
        w.u8(0xFC | (info.chromaFormat & 0x03))   // reserved | chromaFormat
        w.u8(0xF8 | (info.bitDepthLumaMinus8 & 0x07))
        w.u8(0xF8 | (info.bitDepthChromaMinus8 & 0x07))
        w.u16(0)                                  // avgFrameRate
        // constantFrameRate(2)=0 | numTemporalLayers(3) | temporalIdNested(1) | lengthSizeMinusOne(2)=3
        w.u8(((info.numTemporalLayers & 0x07) << 3) | ((info.temporalIdNested & 0x01) << 2) | 0x03)
        w.u8(3)                                   // numOfArrays: VPS, SPS, PPS

        func array(type: UInt8, nalu: [UInt8]) {
            w.u8(type & 0x3F)                     // array_completeness=0 | NAL_unit_type
            w.u16(1)                              // numNalus
            w.u16(UInt16(nalu.count)); w.bytes(nalu)
        }
        array(type: HEVC.NALType.vps, nalu: vps)
        array(type: HEVC.NALType.sps, nalu: sps)
        array(type: HEVC.NALType.pps, nalu: pps)
        return MP4Box.box("hvcC", w.data)
    }

    // MARK: Audio track

    private func audioTrak() -> Data {
        let audio = self.audio!
        return MP4Box.box("trak", MP4Box.concat([
            tkhd(trackID: audioTrackID, width: 0, height: 0, isAudio: true),
            MP4Box.box("mdia", MP4Box.concat([
                mdhd(timescale: audioTimescale),
                hdlr(handlerType: "soun", name: "SoundHandler"),
                MP4Box.box("minf", MP4Box.concat([
                    smhd(), dinf(),
                    MP4Box.box("stbl", MP4Box.concat([
                        MP4Box.box("stsd", stsdBody(sampleEntry: audioSampleEntry(audio))),
                        emptyFullBox("stts"), emptyFullBox("stsc"),
                        stsz(), emptyFullBox("stco"),
                    ])),
                ])),
            ])),
        ]))
    }

    /// `mp4a`/`esds` for AAC, `ac-3`/`dac3` for AC-3.
    private func audioSampleEntry(_ audio: AudioFormat) -> Data {
        let (type, config) = audio.codec == .ac3 ? ("ac-3", dac3(audio)) : ("mp4a", esds(audio))
        var w = ByteWriter()
        for _ in 0..<6 { w.u8(0) }              // reserved
        w.u16(1)                                 // data_reference_index
        w.u32(0); w.u32(0)                       // reserved
        w.u16(UInt16(max(audio.channels, 1)))    // channel count
        w.u16(16)                                // sample size
        w.u16(0); w.u16(0)                       // pre_defined / reserved
        w.u32(UInt32(audio.sampleRate) << 16)    // sample rate 16.16
        w.append(config)
        return MP4Box.box(type, w.data)
    }

    /// AC3SpecificBox — the 3-byte payload is computed by the AC-3 parser.
    private func dac3(_ audio: AudioFormat) -> Data {
        MP4Box.box("dac3", audio.decoderConfig)
    }

    private func esds(_ audio: AudioFormat) -> Data {
        let asc = [UInt8](audio.decoderConfig)

        func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [tag, UInt8(payload.count)] + payload
        }

        let dsi = descriptor(0x05, asc)                    // DecoderSpecificInfo
        var dcd: [UInt8] = [0x40, 0x15]                    // AAC, audioStream
        dcd += [0, 0, 0]                                    // bufferSizeDB
        dcd += [0, 0, 0, 0]                                // maxBitrate
        dcd += [0, 0, 0, 0]                                // avgBitrate
        dcd += dsi
        let decoderConfig = descriptor(0x04, dcd)
        let slConfig = descriptor(0x06, [0x02])
        var es: [UInt8] = [0x00, 0x00, 0x00]               // ES_ID(2) + flags(1)
        es += decoderConfig
        es += slConfig
        let esDescriptor = descriptor(0x03, es)

        return MP4Box.fullBox("esds", version: 0, flags: 0, Data(esDescriptor))
    }

    // MARK: Shared track boxes

    private func tkhd(trackID: UInt32, width: Int, height: Int, isAudio: Bool) -> Data {
        var w = ByteWriter()
        w.u32(0); w.u32(0)                  // creation / modification time
        w.u32(trackID)
        w.u32(0)                            // reserved
        w.u32(0)                            // duration
        w.u32(0); w.u32(0)                  // reserved
        w.u16(0)                            // layer
        w.u16(0)                            // alternate_group
        w.u16(isAudio ? 0x0100 : 0)         // volume
        w.u16(0)                            // reserved
        for v in unityMatrix { w.u32(v) }
        w.u32(UInt32(width) << 16)          // width 16.16
        w.u32(UInt32(height) << 16)         // height 16.16
        // flags: track_enabled | track_in_movie | track_in_preview
        return MP4Box.fullBox("tkhd", version: 0, flags: 0x0000_07, w.data)
    }

    private func mdhd(timescale: UInt32) -> Data {
        var w = ByteWriter()
        w.u32(0); w.u32(0)                  // creation / modification time
        w.u32(timescale)
        w.u32(0)                            // duration
        w.u16(0x55C4)                       // language 'und'
        w.u16(0)                            // pre_defined
        return MP4Box.fullBox("mdhd", version: 0, flags: 0, w.data)
    }

    private func hdlr(handlerType: String, name: String) -> Data {
        var w = ByteWriter()
        w.u32(0)                            // pre_defined
        w.fourCC(handlerType)
        w.u32(0); w.u32(0); w.u32(0)        // reserved
        w.bytes(Array(name.utf8)); w.u8(0)  // null-terminated name
        return MP4Box.fullBox("hdlr", version: 0, flags: 0, w.data)
    }

    private func vmhd() -> Data {
        var w = ByteWriter()
        w.u16(0)                            // graphicsmode
        w.u16(0); w.u16(0); w.u16(0)        // opcolor
        return MP4Box.fullBox("vmhd", version: 0, flags: 1, w.data)
    }

    private func smhd() -> Data {
        var w = ByteWriter()
        w.u16(0)                            // balance
        w.u16(0)                            // reserved
        return MP4Box.fullBox("smhd", version: 0, flags: 0, w.data)
    }

    private func dinf() -> Data {
        // dref with a single self-contained url entry (flags = 1).
        let url = MP4Box.fullBox("url ", version: 0, flags: 1, Data())
        var drefBody = ByteWriter()
        drefBody.u32(1)                     // entry_count
        drefBody.append(url)
        let dref = MP4Box.fullBox("dref", version: 0, flags: 0, drefBody.data)
        return MP4Box.box("dinf", dref)
    }

    private func stsdBody(sampleEntry: Data) -> Data {
        var w = ByteWriter()
        w.u8(0); w.u24(0)                   // version + flags
        w.u32(1)                            // entry_count
        w.append(sampleEntry)
        return w.data
    }

    private func stsz() -> Data {
        var w = ByteWriter()
        w.u32(0)                            // sample_size (0 => per-sample sizes)
        w.u32(0)                            // sample_count
        return MP4Box.fullBox("stsz", version: 0, flags: 0, w.data)
    }

    /// A version-0 full box whose payload is a single zero entry-count.
    private func emptyFullBox(_ type: String) -> Data {
        var w = ByteWriter()
        w.u32(0)                            // entry_count
        return MP4Box.fullBox(type, version: 0, flags: 0, w.data)
    }

    // MARK: - moof + mdat

    private func buildFragment(videoSamples: [Sample],
                               audioSamples: [Sample],
                               videoBaseDecodeTime: UInt64,
                               audioBasePTS: UInt64) -> Data {
        let videoBytes = videoSamples.reduce(0) { $0 + $1.data.count }

        // Build moof once with placeholder offsets to learn its size, then
        // rebuild with real data offsets (field widths are fixed, so the size
        // does not change).
        func moof(videoOffset: Int, audioOffset: Int) -> Data {
            var trafs: [Data] = []
            if !videoSamples.isEmpty {
                trafs.append(traf(trackID: videoTrackID,
                                  baseDecodeTime: videoBaseDecodeTime,
                                  samples: videoSamples,
                                  dataOffset: videoOffset,
                                  perSampleFlags: true))
            }
            if !audioSamples.isEmpty {
                let audioDecodeTime = audioBasePTS * UInt64(audioTimescale) / UInt64(videoTimescale)
                trafs.append(traf(trackID: audioTrackID,
                                  baseDecodeTime: audioDecodeTime,
                                  samples: audioSamples,
                                  dataOffset: audioOffset,
                                  perSampleFlags: false))
            }
            return MP4Box.box("moof", MP4Box.concat([mfhd()] + trafs))
        }

        let probeSize = moof(videoOffset: 0, audioOffset: 0).count
        let videoOffset = probeSize + 8                 // + mdat header
        let audioOffset = videoOffset + videoBytes
        let realMoof = moof(videoOffset: videoOffset, audioOffset: audioOffset)

        var mdatBody = Data()
        for s in videoSamples { mdatBody.append(s.data) }
        for s in audioSamples { mdatBody.append(s.data) }
        let mdat = MP4Box.box("mdat", mdatBody)

        let moofAndMdat = MP4Box.concat([realMoof, mdat])
        let videoDuration = videoSamples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
        let sidx = sidx(referencedSize: moofAndMdat.count,
                        earliestPresentationTime: videoBaseDecodeTime,
                        subsegmentDuration: videoDuration > 0 ? videoDuration : UInt64(videoTimescale))

        // HLS fMP4 media segments: styp + sidx (segment index) + moof + mdat.
        // `default-base-is-moof` keeps trun offsets relative to the moof, so the
        // leading styp/sidx do not affect them.
        return MP4Box.concat([styp(), sidx, moofAndMdat])
    }

    private func styp() -> Data {
        var w = ByteWriter()
        w.fourCC("msdh")    // major brand
        w.u32(0)            // minor version
        w.fourCC("msdh"); w.fourCC("msix")
        return MP4Box.box("styp", w.data)
    }

    /// Segment Index box describing the single subsegment (moof + mdat) that
    /// follows it. AVPlayer's HLS engine requires a `sidx` in fMP4 segments.
    private func sidx(referencedSize: Int, earliestPresentationTime: UInt64, subsegmentDuration: UInt64) -> Data {
        var w = ByteWriter()
        w.u32(videoTrackID)                          // reference_ID
        w.u32(videoTimescale)                        // timescale
        w.u64(earliestPresentationTime)              // earliest_presentation_time (v1)
        w.u64(0)                                     // first_offset (sidx abuts the moof)
        w.u16(0)                                     // reserved
        w.u16(1)                                     // reference_count
        w.u32(UInt32(referencedSize) & 0x7FFF_FFFF)  // reference_type(0) | referenced_size
        w.u32(UInt32(truncatingIfNeeded: subsegmentDuration)) // subsegment_duration
        w.u32(0x9000_0000)                           // starts_with_SAP=1, SAP_type=1
        return MP4Box.fullBox("sidx", version: 1, flags: 0, w.data)
    }

    private func mfhd() -> Data {
        var w = ByteWriter()
        w.u32(sequenceNumber)
        return MP4Box.fullBox("mfhd", version: 0, flags: 0, w.data)
    }

    private func traf(trackID: UInt32,
                      baseDecodeTime: UInt64,
                      samples: [Sample],
                      dataOffset: Int,
                      perSampleFlags: Bool) -> Data {
        // tfhd: default-base-is-moof so trun offsets are relative to the moof.
        var tfhdBody = ByteWriter()
        tfhdBody.u32(trackID)
        let tfhd = MP4Box.fullBox("tfhd", version: 0, flags: 0x02_0000, tfhdBody.data)

        // tfdt (version 1, 64-bit baseMediaDecodeTime).
        var tfdtBody = ByteWriter()
        tfdtBody.u64(baseDecodeTime)
        let tfdt = MP4Box.fullBox("tfdt", version: 1, flags: 0, tfdtBody.data)

        // trun: data-offset + per-sample duration, size, and (optionally) flags.
        var trunFlags: UInt32 = 0x0001    // data-offset-present
        trunFlags |= 0x0100               // sample-duration-present
        trunFlags |= 0x0200               // sample-size-present
        if perSampleFlags { trunFlags |= 0x0400 } // sample-flags-present

        var trunBody = ByteWriter()
        trunBody.u32(UInt32(samples.count))
        trunBody.u32(UInt32(bitPattern: Int32(dataOffset)))
        for s in samples {
            trunBody.u32(s.duration)
            trunBody.u32(UInt32(s.data.count))
            if perSampleFlags { trunBody.u32(s.flags) }
        }
        let trun = MP4Box.fullBox("trun", version: 0, flags: trunFlags, trunBody.data)

        return MP4Box.box("traf", MP4Box.concat([tfhd, tfdt, trun]))
    }

    // MARK: - Helpers

    private let unityMatrix: [UInt32] = [
        0x0001_0000, 0, 0,
        0, 0x0001_0000, 0,
        0, 0, 0x4000_0000,
    ]

    private func compressorName(_ name: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let utf8 = Array(name.utf8.prefix(31))
        bytes[0] = UInt8(utf8.count)
        for (i, b) in utf8.enumerated() { bytes[i + 1] = b }
        return bytes
    }
}
