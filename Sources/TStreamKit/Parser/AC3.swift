import Foundation

/// AC-3 (Dolby Digital) helpers: framing a PES payload into complete sync frames
/// and deriving the `dac3` decoder-configuration payload. AC-3 is passed through
/// untouched — each sync frame becomes one fMP4 sample of 1536 audio samples.
enum AC3 {
    /// Each AC-3 sync frame decodes to this many PCM samples.
    static let samplesPerFrame = 1536

    /// Sampling frequency by `fscod`; `3` is reserved.
    static let sampleRates: [Int] = [48000, 44100, 32000]

    /// Channel count by `acmod`, before adding the optional LFE channel.
    private static let channelsByAcmod = [2, 1, 2, 3, 3, 4, 4, 5]

    /// Frame size in 16-bit words per `frmsizecod`, columns ordered by `fscod`
    /// (48 kHz, 44.1 kHz, 32 kHz). From ATSC A/52 Table 5.18.
    private static let frameSizeWords: [(w48: Int, w441: Int, w32: Int)] = [
        (64, 69, 96), (64, 70, 96), (80, 87, 120), (80, 88, 120),
        (96, 104, 144), (96, 105, 144), (112, 121, 168), (112, 122, 168),
        (128, 139, 192), (128, 140, 192), (160, 174, 240), (160, 175, 240),
        (192, 208, 288), (192, 209, 288), (224, 243, 336), (224, 244, 336),
        (256, 278, 384), (256, 279, 384), (320, 348, 480), (320, 349, 480),
        (384, 417, 576), (384, 418, 576), (448, 487, 672), (448, 488, 672),
        (512, 557, 768), (512, 558, 768), (640, 696, 960), (640, 697, 960),
        (768, 835, 1152), (768, 836, 1152), (896, 975, 1344), (896, 976, 1344),
        (1024, 1114, 1536), (1024, 1115, 1536), (1152, 1253, 1728), (1152, 1254, 1728),
        (1280, 1393, 1920), (1280, 1394, 1920),
    ]

    struct Frame {
        /// The complete AC-3 sync frame, used verbatim as the fMP4 sample.
        let raw: ArraySlice<UInt8>
    }

    struct Config {
        let sampleRate: Int
        let channels: Int
        /// The 3-byte `dac3` box payload describing the bitstream.
        let dac3: Data
    }

    /// Number of bytes in the sync frame beginning at `i`, or `nil` if the header
    /// is invalid/incomplete.
    private static func frameSize(_ data: [UInt8], _ i: Int) -> Int? {
        guard i + 5 <= data.count, data[i] == 0x0B, data[i + 1] == 0x77 else { return nil }
        let fscod = Int(data[i + 4] >> 6)
        let frmsizecod = Int(data[i + 4] & 0x3F)
        guard fscod < 3, frmsizecod < frameSizeWords.count else { return nil }
        let words = frameSizeWords[frmsizecod]
        let count = fscod == 0 ? words.w48 : (fscod == 1 ? words.w441 : words.w32)
        return count * 2
    }

    /// Walks an AC-3 byte stream and yields each complete sync frame.
    static func frames(in data: [UInt8]) -> [Frame] {
        var frames: [Frame] = []
        var i = 0
        let n = data.count
        while i + 5 <= n {
            guard let size = frameSize(data, i) else { i += 1; continue }
            guard i + size <= n else { break }
            frames.append(Frame(raw: data[i..<(i + size)]))
            i += size
        }
        return frames
    }

    /// Decodes sample rate, channel count, and the `dac3` payload from a frame.
    static func config(from frame: ArraySlice<UInt8>) -> Config? {
        let b = Array(frame)
        guard b.count >= 6, b[0] == 0x0B, b[1] == 0x77 else { return nil }
        let fscod = b[4] >> 6
        let frmsizecod = b[4] & 0x3F
        guard fscod < 3 else { return nil }

        let bsid = b[5] >> 3
        let bsmod = b[5] & 0x07

        // bsi() begins at byte 5: bsid(5) bsmod(3) acmod(3) ...
        var reader = BitReader(Array(b[5...]))
        _ = reader.readBits(5)              // bsid
        _ = reader.readBits(3)              // bsmod
        let acmodBits = UInt8(reader.readBits(3) ?? 0)
        if (acmodBits & 0x01) != 0, acmodBits != 0x01 { _ = reader.readBits(2) } // cmixlev
        if (acmodBits & 0x04) != 0 { _ = reader.readBits(2) }                    // surmixlev
        if acmodBits == 0x02 { _ = reader.readBits(2) }                          // dsurmod
        let lfeon = UInt8(reader.readBits(1) ?? 0)

        let sampleRate = sampleRates[Int(fscod)]
        let channels = channelsByAcmod[Int(acmodBits)] + Int(lfeon)
        let bitRateCode = frmsizecod >> 1

        // dac3 payload (19 used bits, left-aligned in 24): fscod(2) bsid(5)
        // bsmod(3) acmod(3) lfeon(1) bit_rate_code(5) reserved(5).
        var value: UInt32 = 0
        value |= UInt32(fscod) << 22
        value |= UInt32(bsid) << 17
        value |= UInt32(bsmod) << 14
        value |= UInt32(acmodBits) << 11
        value |= UInt32(lfeon) << 10
        value |= UInt32(bitRateCode) << 5
        let dac3 = Data([UInt8((value >> 16) & 0xFF),
                         UInt8((value >> 8) & 0xFF),
                         UInt8(value & 0xFF)])

        return Config(sampleRate: sampleRate, channels: channels, dac3: dac3)
    }
}
