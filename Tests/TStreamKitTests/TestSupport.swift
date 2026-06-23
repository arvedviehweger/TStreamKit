import Foundation
@testable import TStreamKit

/// Builders for synthetic MPEG-TS structures used across the test suite.
enum TS {
    /// Wraps a payload (<= 184 bytes) into a single 188-byte TS packet,
    /// padding the remainder with `0xFF`.
    static func packet(pid: UInt16, payloadUnitStart: Bool, continuityCounter: UInt8 = 0, payload: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0xFF, count: 188)
        p[0] = 0x47
        p[1] = (payloadUnitStart ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F)
        p[2] = UInt8(pid & 0xFF)
        p[3] = 0x10 | (continuityCounter & 0x0F) // adaptation_field_control = 01
        for (i, b) in payload.prefix(184).enumerated() { p[4 + i] = b }
        return p
    }

    /// Encodes a 33-bit PTS/DTS into the 5-byte PES timestamp layout.
    static func timestamp(_ ts: UInt64, prefix: UInt8) -> [UInt8] {
        [
            (prefix << 4) | UInt8(((ts >> 30) & 0x07) << 1) | 0x01,
            UInt8((ts >> 22) & 0xFF),
            UInt8(((ts >> 15) & 0x7F) << 1) | 0x01,
            UInt8((ts >> 7) & 0xFF),
            UInt8((ts & 0x7F) << 1) | 0x01,
        ]
    }

    /// Builds a PES packet (PTS only) with the given elementary payload.
    static func pes(streamID: UInt8, pts: UInt64, payload: [UInt8]) -> [UInt8] {
        var pes: [UInt8] = [0x00, 0x00, 0x01, streamID, 0x00, 0x00]
        pes += [0x80, 0x80, 0x05]            // marker, PTS-only flag, header length 5
        pes += timestamp(pts, prefix: 0x2)
        pes += payload
        return pes
    }

    /// A minimal PAT mapping one program to a PMT PID.
    static func pat(pmtPID: UInt16) -> [UInt8] {
        var b: [UInt8] = [
            0x00,             // pointer_field
            0x00,             // table_id (PAT)
            0xB0, 0x0D,       // section_syntax + length = 13
            0x00, 0x01,       // transport_stream_id
            0xC1,             // version / current_next
            0x00, 0x00,       // section / last section
            0x00, 0x01,       // program_number = 1
            UInt8(0xE0 | UInt8((pmtPID >> 8) & 0x1F)), UInt8(pmtPID & 0xFF),
            0x00, 0x00, 0x00, 0x00, // CRC (not validated)
        ]
        b.reserveCapacity(b.count)
        return b
    }

    /// A PMT advertising one H.264 video and one AAC audio elementary stream.
    static func pmt(videoPID: UInt16, audioPID: UInt16) -> [UInt8] {
        [
            0x00,             // pointer_field
            0x02,             // table_id (PMT)
            0xB0, 0x17,       // section_syntax + length = 23
            0x00, 0x01,       // program_number
            0xC1,             // version / current_next
            0x00, 0x00,       // section / last section
            UInt8(0xE0 | UInt8((videoPID >> 8) & 0x1F)), UInt8(videoPID & 0xFF), // PCR_PID
            0xF0, 0x00,       // program_info_length = 0
            0x1B, UInt8(0xE0 | UInt8((videoPID >> 8) & 0x1F)), UInt8(videoPID & 0xFF), 0xF0, 0x00, // H.264
            0x0F, UInt8(0xE0 | UInt8((audioPID >> 8) & 0x1F)), UInt8(audioPID & 0xFF), 0xF0, 0x00, // AAC
            0x00, 0x00, 0x00, 0x00, // CRC
        ]
    }

    /// A PMT advertising one H.264 video stream plus arbitrary audio ES entries,
    /// each `(stream_type, PID, ES-info descriptors)`. The section_length is
    /// computed so the demuxer's bounds math is exercised for real.
    static func pmt(videoPID: UInt16, videoStreamType: UInt8 = 0x1B,
                    audio: [(streamType: UInt8, pid: UInt16, descriptors: [UInt8])]) -> [UInt8] {
        func es(_ streamType: UInt8, _ pid: UInt16, _ desc: [UInt8]) -> [UInt8] {
            [streamType,
             UInt8(0xE0 | UInt8((pid >> 8) & 0x1F)), UInt8(pid & 0xFF),
             UInt8(0xF0 | UInt8((desc.count >> 8) & 0x0F)), UInt8(desc.count & 0xFF)] + desc
        }

        var loop = es(videoStreamType, videoPID, [])           // video (default H.264)
        for a in audio { loop += es(a.streamType, a.pid, a.descriptors) }

        // section_length spans program_number..CRC: 9 fixed bytes + ES loop + 4 CRC.
        let sectionLength = 9 + loop.count + 4
        var b: [UInt8] = [
            0x00,             // pointer_field
            0x02,             // table_id (PMT)
            UInt8(0xB0 | UInt8((sectionLength >> 8) & 0x0F)), UInt8(sectionLength & 0xFF),
            0x00, 0x01,       // program_number
            0xC1,             // version / current_next
            0x00, 0x00,       // section / last section
            UInt8(0xE0 | UInt8((videoPID >> 8) & 0x1F)), UInt8(videoPID & 0xFF), // PCR_PID
            0xF0, 0x00,       // program_info_length = 0
        ]
        b += loop
        b += [0x00, 0x00, 0x00, 0x00] // CRC (not validated)
        return b
    }

    /// One E-AC-3 syncframe of `sizeBytes` bytes (header + zero padding).
    /// Defaults: independent substream, 48 kHz, 6 blocks (1536 samples), stereo.
    static func eac3Frame(sizeBytes: Int = 128, strmtyp: Int = 0,
                          fscod: Int = 0, numblkscod: Int = 3,
                          acmod: Int = 2, lfeon: Int = 0) -> [UInt8] {
        precondition(sizeBytes % 2 == 0 && sizeBytes >= 6)
        var bw = BitWriter()
        bw.write(0x0B77, 16)                    // syncword
        bw.write(strmtyp, 2)
        bw.write(0, 3)                          // substreamid
        bw.write(sizeBytes / 2 - 1, 11)         // frmsiz
        bw.write(fscod, 2)
        bw.write(fscod == 3 ? 0 : numblkscod, 2) // fscod2 or numblkscod
        bw.write(acmod, 3)
        bw.write(lfeon, 1)
        var bytes = bw.bytes
        if bytes.count < sizeBytes { bytes += [UInt8](repeating: 0, count: sizeBytes - bytes.count) }
        return Array(bytes.prefix(sizeBytes))
    }

    /// A single 128-byte AC-3 sync frame: 48 kHz, stereo, no LFE.
    static func ac3Frame() -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 128)
        frame[0] = 0x0B; frame[1] = 0x77   // syncword
        frame[4] = 0x00                     // fscod=0 (48k), frmsizecod=0
        frame[5] = 0x40                     // bsid=8, bsmod=0
        frame[6] = 0x40                     // acmod=2 (stereo)
        return frame
    }

    /// Builds a LOAS `AudioSyncStream` frame carrying one AAC-LC access unit in
    /// LATM (audioMuxVersion 0, one program/layer, frameLengthType 0). With
    /// `sameStreamMux` the StreamMuxConfig is omitted (reuses the previous one).
    static func loasAAC(payload: [UInt8], sampleRateIndex: Int = 3, channels: Int = 2,
                        sameStreamMux: Bool = false) -> [UInt8] {
        var bw = BitWriter()
        bw.write(sameStreamMux ? 1 : 0, 1)          // useSameStreamMux
        if !sameStreamMux {
            // StreamMuxConfig
            bw.write(0, 1)                          // audioMuxVersion
            bw.write(1, 1)                          // allStreamsSameTimeFraming
            bw.write(0, 6)                          // numSubFrames
            bw.write(0, 4)                          // numProgram
            bw.write(0, 3)                          // numLayer
            // AudioSpecificConfig (AAC-LC)
            bw.write(2, 5)                          // audioObjectType
            bw.write(sampleRateIndex, 4)
            bw.write(channels, 4)
            bw.write(0, 1); bw.write(0, 1); bw.write(0, 1) // GASpecificConfig: frameLengthFlag/depends/ext
            bw.write(0, 3)                          // frameLengthType
            bw.write(0xFF, 8)                       // latmBufferFullness
            bw.write(0, 1)                          // otherDataPresent
            bw.write(0, 1)                          // crcCheckPresent
        }
        var len = payload.count                     // PayloadLengthInfo
        while len >= 255 { bw.write(255, 8); len -= 255 }
        bw.write(len, 8)
        for b in payload { bw.write(Int(b), 8) }    // PayloadMux
        bw.align()

        let element = bw.bytes
        let n = element.count
        return [0x56, UInt8(0xE0 | UInt8((n >> 8) & 0x1F)), UInt8(n & 0xFF)] + element
    }

    /// Builds an Annex-B H.264 access unit from the given NAL units.
    static func annexB(_ nals: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for nal in nals {
            out += [0x00, 0x00, 0x00, 0x01]
            out += nal
        }
        return out
    }

    /// Builds a single ADTS-framed AAC packet.
    static func adts(payload: [UInt8], sampleRateIndex: Int = 4, channels: Int = 2, profile: Int = 1) -> [UInt8] {
        let frameLength = 7 + payload.count
        var h = [UInt8](repeating: 0, count: 7)
        h[0] = 0xFF
        h[1] = 0xF1 // sync + MPEG-4 + protection_absent
        let h2: Int = (profile << 6) | (sampleRateIndex << 2) | ((channels >> 2) & 1)
        let h3: Int = ((channels & 3) << 6) | ((frameLength >> 11) & 0x03)
        let h4: Int = (frameLength >> 3) & 0xFF
        let h5: Int = ((frameLength & 0x07) << 5) | 0x1F
        h[2] = UInt8(h2)
        h[3] = UInt8(h3)
        h[4] = UInt8(h4)
        h[5] = UInt8(h5)
        h[6] = 0xFC
        return h + payload
    }
}

/// Minimal MSB-first bit writer for synthesizing bit-packed test streams.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: Int, _ count: Int) {
        for k in stride(from: count - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if (value >> k) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(1 << (7 - (bitCount % 8))) }
            bitCount += 1
        }
    }

    /// Pads with zero bits to the next byte boundary.
    mutating func align() { while bitCount % 8 != 0 { write(0, 1) } }
}

