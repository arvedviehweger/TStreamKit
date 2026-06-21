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

/// Scans a `Data` blob for a 4-character box type (FourCC).
func dataContains(_ data: Data, fourCC: String) -> Bool {
    let needle = Array(fourCC.utf8)
    let bytes = [UInt8](data)
    guard needle.count <= bytes.count else { return false }
    for i in 0...(bytes.count - needle.count) where Array(bytes[i..<i + needle.count]) == needle {
        return true
    }
    return false
}

/// Walks the top-level ISO BMFF boxes and verifies declared sizes tile the
/// buffer exactly. Returns the ordered list of box types, or nil on overflow.
func topLevelBoxes(_ data: Data) -> [String]? {
    let bytes = [UInt8](data)
    var i = 0
    var types: [String] = []
    while i + 8 <= bytes.count {
        let size = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        guard size >= 8, i + size <= bytes.count else { return nil }
        let type = String(bytes: bytes[i + 4..<i + 8], encoding: .ascii) ?? "????"
        types.append(type)
        i += size
    }
    return i == bytes.count ? types : nil
}
