import Foundation

/// H.264 (AVC) Annex-B helpers: splitting the byte-stream into NAL units,
/// converting to length-prefixed AVCC, and extracting parameter sets.
enum H264 {
    /// NAL unit types we care about (`nal_unit_type`, lower 5 bits of byte 0).
    enum NALType: UInt8 {
        case nonIDR = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case accessUnitDelimiter = 9
    }

    struct NAL {
        let type: UInt8
        let bytes: ArraySlice<UInt8>
    }

    /// Splits an Annex-B buffer into NAL units, locating 3- and 4-byte start
    /// codes (`00 00 01` / `00 00 00 01`).
    static func splitNALUnits(_ data: [UInt8]) -> [NAL] {
        var nals: [NAL] = []
        let n = data.count
        var i = 0

        // Find the first start code.
        func startCodeLength(at p: Int) -> Int {
            if p + 3 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 1 { return 3 }
            if p + 4 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 0, data[p + 3] == 1 { return 4 }
            return 0
        }

        // Advance to first start code.
        while i < n, startCodeLength(at: i) == 0 { i += 1 }

        while i < n {
            let scLen = startCodeLength(at: i)
            guard scLen > 0 else { break }
            let nalStart = i + scLen

            // Find next start code.
            var j = nalStart
            var nextSC = 0
            while j < n {
                let l = startCodeLength(at: j)
                if l > 0 { nextSC = l; break }
                j += 1
            }
            let nalEnd = j
            if nalStart < nalEnd {
                let type = data[nalStart] & 0x1F
                nals.append(NAL(type: type, bytes: data[nalStart..<nalEnd]))
            }
            if nextSC == 0 { break }
            i = j
        }
        return nals
    }

    /// Builds an AVCC access unit (4-byte length prefixes) from NAL units,
    /// dropping parameter sets and access-unit delimiters (those live in the
    /// `avcC` config box, not the sample data).
    static func avccSample(from nals: [NAL]) -> (data: Data, isKeyframe: Bool) {
        var out = Data()
        var keyframe = false
        for nal in nals {
            switch nal.type {
            case NALType.sps.rawValue, NALType.pps.rawValue, NALType.accessUnitDelimiter.rawValue:
                continue
            case NALType.idr.rawValue:
                keyframe = true
            default:
                break
            }
            let length = UInt32(nal.bytes.count)
            out.append(UInt8((length >> 24) & 0xFF))
            out.append(UInt8((length >> 16) & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
            out.append(contentsOf: nal.bytes)
        }
        return (out, keyframe)
    }

    /// Coded picture dimensions decoded from an SPS, when available.
    struct Dimensions { let width: Int; let height: Int }

    /// Minimal SPS parser: decodes just enough to recover frame width/height.
    /// Returns `nil` if the SPS is too short or uses fields we don't decode.
    static func parseSPS(_ sps: ArraySlice<UInt8>) -> Dimensions? {
        // Strip emulation-prevention bytes and the NAL header byte.
        let raw = Array(sps)
        guard raw.count > 1 else { return nil }
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(raw.count)
        var zeroRun = 0
        for k in 1..<raw.count {
            let byte = raw[k]
            if zeroRun >= 2, byte == 0x03 { zeroRun = 0; continue }
            rbsp.append(byte)
            zeroRun = (byte == 0) ? zeroRun + 1 : 0
        }

        var reader = BitReader(rbsp)
        guard let profileIdc = reader.readBits(8) else { return nil }
        _ = reader.readBits(8)            // constraint flags + reserved
        _ = reader.readBits(8)            // level_idc
        _ = reader.readUE()               // seq_parameter_set_id

        let highProfiles: Set<UInt32> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if highProfiles.contains(profileIdc) {
            let chromaFormat = reader.readUE() ?? 0
            if chromaFormat == 3 { _ = reader.readBits(1) }
            _ = reader.readUE()           // bit_depth_luma_minus8
            _ = reader.readUE()           // bit_depth_chroma_minus8
            _ = reader.readBits(1)        // qpprime_y_zero_transform_bypass_flag
            let seqScalingMatrix = reader.readBits(1) ?? 0
            if seqScalingMatrix == 1 {
                let lists = chromaFormat != 3 ? 8 : 12
                for _ in 0..<lists { _ = reader.readBits(1) }
            }
        }

        _ = reader.readUE()               // log2_max_frame_num_minus4
        let picOrderCntType = reader.readUE() ?? 0
        if picOrderCntType == 0 {
            _ = reader.readUE()           // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            _ = reader.readBits(1)
            _ = reader.readSE()
            _ = reader.readSE()
            let n = reader.readUE() ?? 0
            for _ in 0..<n { _ = reader.readSE() }
        }
        _ = reader.readUE()               // max_num_ref_frames
        _ = reader.readBits(1)            // gaps_in_frame_num_value_allowed_flag

        guard let picWidthInMbsMinus1 = reader.readUE(),
              let picHeightInMapUnitsMinus1 = reader.readUE(),
              let frameMbsOnly = reader.readBits(1) else { return nil }

        if frameMbsOnly == 0 { _ = reader.readBits(1) } // mb_adaptive_frame_field_flag
        _ = reader.readBits(1)            // direct_8x8_inference_flag

        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if reader.readBits(1) == 1 {      // frame_cropping_flag
            cropLeft = Int(reader.readUE() ?? 0)
            cropRight = Int(reader.readUE() ?? 0)
            cropTop = Int(reader.readUE() ?? 0)
            cropBottom = Int(reader.readUE() ?? 0)
        }

        let width = (Int(picWidthInMbsMinus1) + 1) * 16
        let heightMapUnits = (Int(picHeightInMapUnitsMinus1) + 1) * 16
        let height = heightMapUnits * (frameMbsOnly == 1 ? 1 : 2)

        // Crop is specified in chroma sample units; assume 4:2:0 (factor 2).
        let croppedWidth = width - (cropLeft + cropRight) * 2
        let croppedHeight = height - (cropTop + cropBottom) * 2
        guard croppedWidth > 0, croppedHeight > 0 else { return nil }
        return Dimensions(width: croppedWidth, height: croppedHeight)
    }
}

/// Big-endian bit reader with Exp-Golomb helpers for codec headers.
struct BitReader {
    private let bytes: [UInt8]
    private var bitPos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private var bitsRemaining: Int { bytes.count * 8 - bitPos }

    mutating func readBits(_ count: Int) -> UInt32? {
        guard count <= 32, bitsRemaining >= count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bitPos >> 3]
            let bit = (byte >> (7 - (bitPos & 7))) & 1
            value = (value << 1) | UInt32(bit)
            bitPos += 1
        }
        return value
    }

    /// Advances past `count` bits, returning false if the buffer is too short.
    @discardableResult
    mutating func skip(_ count: Int) -> Bool {
        guard bitsRemaining >= count else { return false }
        bitPos += count
        return true
    }

    /// Unsigned Exp-Golomb.
    mutating func readUE() -> UInt32? {
        var leadingZeros = 0
        while true {
            guard let bit = readBits(1) else { return nil }
            if bit == 1 { break }
            leadingZeros += 1
            if leadingZeros > 31 { return nil }
        }
        if leadingZeros == 0 { return 0 }
        guard let suffix = readBits(leadingZeros) else { return nil }
        return (1 << leadingZeros) - 1 + suffix
    }

    /// Signed Exp-Golomb.
    mutating func readSE() -> Int32? {
        guard let ue = readUE() else { return nil }
        let value = Int64(ue)
        let mag = (value + 1) / 2
        return Int32((value & 1) == 1 ? mag : -mag)
    }
}
