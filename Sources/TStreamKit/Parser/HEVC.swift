import Foundation

/// H.265 (HEVC) Annex-B helpers: splitting the byte-stream into NAL units,
/// converting to length-prefixed AVCC-style samples, and decoding enough of the
/// SPS to build an `hvcC` decoder-configuration record. The two-byte NAL header
/// and 6-bit `nal_unit_type` are the only structural differences from H.264.
enum HEVC {
    /// `nal_unit_type` values we act on.
    enum NALType {
        static let vps: UInt8 = 32
        static let sps: UInt8 = 33
        static let pps: UInt8 = 34
        static let accessUnitDelimiter: UInt8 = 35
        /// IRAP pictures (BLA/IDR/CRA) span types 16...23 and are random-access points.
        static let irapRange: ClosedRange<UInt8> = 16...23
    }

    struct NAL {
        let type: UInt8
        let bytes: ArraySlice<UInt8>
    }

    /// Splits an Annex-B buffer into NAL units, locating 3- and 4-byte start
    /// codes. The HEVC `nal_unit_type` lives in bits 1...6 of the first header byte.
    static func splitNALUnits(_ data: [UInt8]) -> [NAL] {
        var nals: [NAL] = []
        let n = data.count
        var i = 0

        func startCodeLength(at p: Int) -> Int {
            if p + 3 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 1 { return 3 }
            if p + 4 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 0, data[p + 3] == 1 { return 4 }
            return 0
        }

        while i < n, startCodeLength(at: i) == 0 { i += 1 }

        while i < n {
            let scLen = startCodeLength(at: i)
            guard scLen > 0 else { break }
            let nalStart = i + scLen

            var j = nalStart
            var nextSC = 0
            while j < n {
                let l = startCodeLength(at: j)
                if l > 0 { nextSC = l; break }
                j += 1
            }
            let nalEnd = j
            if nalStart < nalEnd {
                let type = (data[nalStart] >> 1) & 0x3F
                nals.append(NAL(type: type, bytes: data[nalStart..<nalEnd]))
            }
            if nextSC == 0 { break }
            i = j
        }
        return nals
    }

    /// Builds an AVCC-style access unit (4-byte length prefixes) from NAL units,
    /// dropping parameter sets and access-unit delimiters (those live in `hvcC`).
    /// The sample is a keyframe when it contains an IRAP picture.
    static func sample(from nals: [NAL]) -> (data: Data, isKeyframe: Bool) {
        var out = Data()
        var keyframe = false
        for nal in nals {
            switch nal.type {
            case NALType.vps, NALType.sps, NALType.pps, NALType.accessUnitDelimiter:
                continue
            default:
                if NALType.irapRange.contains(nal.type) { keyframe = true }
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

    struct Dimensions { let width: Int; let height: Int }

    /// Fields lifted from the SPS that the `hvcC` record needs verbatim.
    struct ParameterSetInfo: Sendable {
        /// The 12-byte general `profile_tier_level` block (profile_space through
        /// level_idc), copied straight into `hvcC` and the HLS CODECS string.
        let generalProfileTierLevel: [UInt8]
        let chromaFormat: UInt8
        let bitDepthLumaMinus8: UInt8
        let bitDepthChromaMinus8: UInt8
        let numTemporalLayers: UInt8
        let temporalIdNested: UInt8
        let dimensions: Dimensions
    }

    /// Strips emulation-prevention bytes from a NAL (header included) and decodes
    /// the SPS fields required for `hvcC`. Returns `nil` if the SPS is truncated.
    static func parseSPS(_ nal: ArraySlice<UInt8>) -> ParameterSetInfo? {
        let raw = Array(nal)
        guard raw.count > 2 else { return nil }

        // Remove emulation-prevention three-bytes (00 00 03) across the whole NAL.
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(raw.count)
        var zeroRun = 0
        for byte in raw {
            if zeroRun >= 2, byte == 0x03 { zeroRun = 0; continue }
            rbsp.append(byte)
            zeroRun = (byte == 0) ? zeroRun + 1 : 0
        }

        // rbsp[0..1] = 2-byte NAL header. rbsp[2] holds vps_id(4) + max_sub_layers(3)
        // + temporal_id_nesting(1); the 12-byte general PTL block follows it.
        guard rbsp.count >= 3 + 12 else { return nil }
        let maxSubLayersMinus1 = (rbsp[2] >> 1) & 0x07
        let temporalIdNested = rbsp[2] & 0x01
        let generalPTL = Array(rbsp[3..<15])

        var reader = BitReader(rbsp)
        _ = reader.readBits(16)             // NAL header
        _ = reader.readBits(8)              // vps_id + max_sub_layers + nesting
        _ = reader.skip(96)                 // general profile_tier_level (captured above)

        // Sub-layer profile/level presence flags, then any present sub-layer PTLs.
        var profilePresent = [Bool](repeating: false, count: Int(maxSubLayersMinus1))
        var levelPresent = [Bool](repeating: false, count: Int(maxSubLayersMinus1))
        for i in 0..<Int(maxSubLayersMinus1) {
            profilePresent[i] = (reader.readBits(1) ?? 0) == 1
            levelPresent[i] = (reader.readBits(1) ?? 0) == 1
        }
        if maxSubLayersMinus1 > 0 {
            for _ in Int(maxSubLayersMinus1)..<8 { _ = reader.readBits(2) }
        }
        for i in 0..<Int(maxSubLayersMinus1) {
            if profilePresent[i] { _ = reader.skip(88) }
            if levelPresent[i] { _ = reader.readBits(8) }
        }

        _ = reader.readUE()                 // sps_seq_parameter_set_id
        let chromaFormat = UInt8(reader.readUE() ?? 1)
        if chromaFormat == 3 { _ = reader.readBits(1) } // separate_colour_plane_flag

        guard let picWidth = reader.readUE(), let picHeight = reader.readUE() else { return nil }

        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if reader.readBits(1) == 1 {        // conformance_window_flag
            cropLeft = Int(reader.readUE() ?? 0)
            cropRight = Int(reader.readUE() ?? 0)
            cropTop = Int(reader.readUE() ?? 0)
            cropBottom = Int(reader.readUE() ?? 0)
        }

        let bitDepthLuma = UInt8(reader.readUE() ?? 0)
        let bitDepthChroma = UInt8(reader.readUE() ?? 0)

        // SubWidthC / SubHeightC scale the conformance-window crop offsets.
        let subWidthC = (chromaFormat == 1 || chromaFormat == 2) ? 2 : 1
        let subHeightC = (chromaFormat == 1) ? 2 : 1
        let width = Int(picWidth) - subWidthC * (cropLeft + cropRight)
        let height = Int(picHeight) - subHeightC * (cropTop + cropBottom)
        guard width > 0, height > 0 else { return nil }

        return ParameterSetInfo(generalProfileTierLevel: generalPTL,
                                chromaFormat: chromaFormat,
                                bitDepthLumaMinus8: bitDepthLuma,
                                bitDepthChromaMinus8: bitDepthChroma,
                                numTemporalLayers: maxSubLayersMinus1 + 1,
                                temporalIdNested: temporalIdNested,
                                dimensions: Dimensions(width: width, height: height))
    }

    /// Builds the HLS `CODECS` attribute value (e.g. `hvc1.1.6.L93.B0`) from the
    /// general `profile_tier_level` block.
    static func codecParameters(generalProfileTierLevel ptl: [UInt8]) -> String {
        guard ptl.count >= 12 else { return "hvc1" }
        let profileSpace = (ptl[0] >> 6) & 0x03
        let tierFlag = (ptl[0] >> 5) & 0x01
        let profileIdc = ptl[0] & 0x1F

        // Compatibility flags are emitted in reversed bit order, then as hex.
        let compat = (UInt32(ptl[1]) << 24) | (UInt32(ptl[2]) << 16)
            | (UInt32(ptl[3]) << 8) | UInt32(ptl[4])
        var reversed: UInt32 = 0
        for i in 0..<32 { reversed |= ((compat >> i) & 1) << (31 - i) }

        let spacePrefix = ["", "A", "B", "C"][Int(profileSpace)]
        let tierChar = tierFlag == 0 ? "L" : "H"

        // Six constraint bytes, trailing zeros omitted.
        var constraint = Array(ptl[5..<11])
        while let last = constraint.last, last == 0 { constraint.removeLast() }
        let constraintHex = constraint.map { String(format: "%02X", $0) }.joined(separator: ".")

        var result = "hvc1.\(spacePrefix)\(profileIdc).\(String(reversed, radix: 16))"
            + ".\(tierChar)\(ptl[11])"
        if !constraintHex.isEmpty { result += ".\(constraintHex)" }
        return result
    }
}
