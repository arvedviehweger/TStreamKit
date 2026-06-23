import Foundation

/// AAC carried in LATM/LOAS (DVB `stream_type 0x11`), as opposed to ADTS (0x0F).
///
/// De-multiplexes LOAS `AudioSyncStream` frames into raw AAC access units plus
/// the `AudioSpecificConfig`, so the very same system AAC decoder path used for
/// ADTS (`kAudioFormatMPEG4AAC` + ASC magic cookie) applies. The raw AAC payload
/// (`PayloadMux`) is the bare `raw_data_block`, identical to what `ADTS.frames`
/// hands downstream.
///
/// Scope: the common DVB shape — `audioMuxVersion == 0`, one program / one layer
/// / one subframe, `frameLengthType == 0`, AAC-LC or explicit HE-AAC, and
/// `channelConfiguration != 0` (no embedded program_config_element). Anything
/// outside that yields no frames rather than mis-aligned garbage.
final class LATMParser {
    struct Config {
        let sampleRate: Int
        let channels: Int
        let audioSpecificConfig: Data
    }

    /// Becomes non-nil once a `StreamMuxConfig` has been seen; cached so frames
    /// that set `useSameStreamMux` (reuse the previous config) still decode.
    private(set) var config: Config?
    private var frameLengthType = 0
    /// Partial LOAS frame carried across PES boundaries.
    private var residual: [UInt8] = []

    func reset() {
        config = nil
        frameLengthType = 0
        residual = []
    }

    /// Parses the LOAS frames in one PES payload, returning each contained raw
    /// AAC access unit. `config` is populated as soon as a config frame appears.
    func parse(_ pes: [UInt8]) -> [[UInt8]] {
        var data = residual
        data.append(contentsOf: pes)
        residual = []

        var out: [[UInt8]] = []
        var i = 0
        let n = data.count
        while i + 3 <= n {
            // LOAS AudioSyncStream sync: 0x2B7 (11 bits). Byte-aligned at frame
            // start → byte0 == 0x56, top three bits of byte1 == 0b111.
            guard data[i] == 0x56, (data[i + 1] & 0xE0) == 0xE0 else { i += 1; continue }
            let len = (Int(data[i + 1] & 0x1F) << 8) | Int(data[i + 2])
            guard i + 3 + len <= n else { break }     // frame straddles the PES end
            if len > 0, let frame = parseAudioMuxElement(Array(data[(i + 3)..<(i + 3 + len)])) {
                out.append(frame)
            }
            i += 3 + len
        }
        residual = i < n ? Array(data[i...]) : []      // keep the unconsumed tail (≤ one frame)
        return out
    }

    // MARK: - AudioMuxElement (muxConfigPresent == 1, per AudioSyncStream)

    private func parseAudioMuxElement(_ element: [UInt8]) -> [UInt8]? {
        var br = BitReader(element)
        guard let useSameStreamMux = br.readBits(1) else { return nil }
        if useSameStreamMux == 0 {
            guard parseStreamMuxConfig(&br) else { return nil }
        }
        guard config != nil, frameLengthType == 0 else { return nil }

        // PayloadLengthInfo: MuxSlotLengthBytes = sum of 8-bit values until < 255.
        var muxSlotLength = 0
        while true {
            guard let b = br.readBits(8) else { return nil }
            muxSlotLength += Int(b)
            if b != 255 { break }
        }
        guard muxSlotLength > 0 else { return nil }

        // PayloadMux: the raw AAC access unit, read 8 bits at a time (the
        // bitstream need not be byte-aligned here).
        var payload = [UInt8]()
        payload.reserveCapacity(muxSlotLength)
        for _ in 0..<muxSlotLength {
            guard let b = br.readBits(8) else { return nil }
            payload.append(UInt8(b))
        }
        return payload
    }

    // MARK: - StreamMuxConfig (audioMuxVersion == 0 only)

    private func parseStreamMuxConfig(_ br: inout BitReader) -> Bool {
        guard let audioMuxVersion = br.readBits(1), audioMuxVersion == 0 else { return false }
        guard let allStreamsSameTimeFraming = br.readBits(1),
              let numSubFrames = br.readBits(6),
              let numProgram = br.readBits(4) else { return false }
        // Common DVB shape: one stream, one program, one layer.
        guard allStreamsSameTimeFraming == 1, numSubFrames == 0, numProgram == 0 else { return false }
        guard let numLayer = br.readBits(3), numLayer == 0 else { return false }

        // prog 0 / layer 0 → useSameConfig is implied 0, so AudioSpecificConfig follows.
        guard parseAudioSpecificConfig(&br) else { return false }

        guard let flt = br.readBits(3) else { return false }
        frameLengthType = Int(flt)
        guard frameLengthType == 0 else { return false }   // variable length only
        guard br.readBits(8) != nil else { return false }  // latmBufferFullness

        // otherDataPresent then crcCheckPresent must be consumed: PayloadMux
        // follows in the same bitstream, so the cursor has to land exactly.
        guard let otherDataPresent = br.readBits(1) else { return false }
        if otherDataPresent == 1 {
            var moreData = true
            while moreData {
                guard let esc = br.readBits(1), br.readBits(8) != nil else { return false }
                moreData = (esc == 1)
            }
        }
        guard let crcCheckPresent = br.readBits(1) else { return false }
        if crcCheckPresent == 1 { guard br.readBits(8) != nil else { return false } }
        return true
    }

    // MARK: - AudioSpecificConfig

    private func readAudioObjectType(_ br: inout BitReader) -> Int? {
        guard let a = br.readBits(5) else { return nil }
        if a == 31 { guard let ext = br.readBits(6) else { return nil }; return 32 + Int(ext) }
        return Int(a)
    }

    /// Consumes the AudioSpecificConfig exactly and derives a 2-byte AAC-LC-style
    /// ASC from the base layer's fields (SBR stays implicit, matching the ADTS
    /// path). Returns false for shapes we don't support, leaving `config` unset.
    private func parseAudioSpecificConfig(_ br: inout BitReader) -> Bool {
        guard var audioObjectType = readAudioObjectType(&br) else { return false }
        guard let srIndexBits = br.readBits(4) else { return false }
        let samplingFrequencyIndex = Int(srIndexBits)
        if samplingFrequencyIndex == 0xF { return false }   // explicit 24-bit rate unsupported
        guard let chCfgBits = br.readBits(4) else { return false }
        let channelConfiguration = Int(chCfgBits)
        guard channelConfiguration != 0 else { return false } // PCE not supported

        // Explicit SBR (5) / PS (29): skip the extension SR, then read the base AOT.
        if audioObjectType == 5 || audioObjectType == 29 {
            guard let extSr = br.readBits(4) else { return false }
            if extSr == 0xF { guard br.skip(24) else { return false } }
            guard let baseAOT = readAudioObjectType(&br) else { return false }
            audioObjectType = baseAOT
            if baseAOT == 22 { guard br.skip(4) else { return false } } // extensionChannelConfiguration
        }

        switch audioObjectType {
        case 1, 2, 3, 4, 6, 7, 17, 19, 20, 23:
            guard parseGASpecificConfig(&br, aot: audioObjectType) else { return false }
        default:
            return false
        }

        guard samplingFrequencyIndex < ADTS.sampleRates.count, audioObjectType < 32 else { return false }
        var asc = Data(count: 2)
        asc[0] = UInt8((audioObjectType << 3) | ((samplingFrequencyIndex >> 1) & 0x07))
        asc[1] = UInt8(((samplingFrequencyIndex & 0x01) << 7) | ((channelConfiguration & 0x0F) << 3))
        config = Config(sampleRate: ADTS.sampleRates[samplingFrequencyIndex],
                        channels: channelConfiguration,
                        audioSpecificConfig: asc)
        return true
    }

    /// Consumes GASpecificConfig for the given AOT (channelConfiguration != 0, so
    /// no program_config_element). Only the bit count matters here.
    private func parseGASpecificConfig(_ br: inout BitReader, aot: Int) -> Bool {
        guard br.skip(1) else { return false }                 // frameLengthFlag
        guard let dependsOnCoreCoder = br.readBits(1) else { return false }
        if dependsOnCoreCoder == 1 { guard br.skip(14) else { return false } } // coreCoderDelay
        guard let extensionFlag = br.readBits(1) else { return false }
        if aot == 6 || aot == 20 { guard br.skip(3) else { return false } }    // layerNr
        if extensionFlag == 1 {
            if aot == 22 { guard br.skip(5 + 11) else { return false } }        // numOfSubFrame + layerLength
            if aot == 17 || aot == 19 || aot == 20 || aot == 23 { guard br.skip(3) else { return false } }
            guard br.skip(1) else { return false }             // extensionFlag3
        }
        return true
    }
}
