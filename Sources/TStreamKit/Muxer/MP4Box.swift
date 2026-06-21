import Foundation

/// Big-endian byte accumulator for building ISO BMFF boxes.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8)   { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF)) }
    mutating func u24(_ v: UInt32) {
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }
    mutating func u32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF)); data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF));  data.append(UInt8(v & 0xFF))
    }
    mutating func u64(_ v: UInt64) {
        u32(UInt32((v >> 32) & 0xFFFF_FFFF)); u32(UInt32(v & 0xFFFF_FFFF))
    }
    mutating func i16(_ v: Int16)  { u16(UInt16(bitPattern: v)) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func append(_ d: Data)   { data.append(d) }
    mutating func fourCC(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
}

/// ISO Base Media File Format box helpers (ISO/IEC 14496-12).
enum MP4Box {
    /// A plain box: `size (4) | type (4) | payload`.
    static func box(_ type: String, _ payload: Data) -> Data {
        var w = ByteWriter()
        w.u32(UInt32(payload.count + 8))
        w.fourCC(type)
        w.append(payload)
        return w.data
    }

    /// A full box: adds a 1-byte version and 3-byte flags ahead of the payload.
    static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ payload: Data) -> Data {
        var w = ByteWriter()
        w.u8(version)
        w.u24(flags)
        w.append(payload)
        return box(type, w.data)
    }

    /// Concatenates several box payloads.
    static func concat(_ parts: [Data]) -> Data {
        var out = Data()
        for p in parts { out.append(p) }
        return out
    }
}
