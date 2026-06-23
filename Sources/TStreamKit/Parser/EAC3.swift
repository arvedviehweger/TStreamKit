import Foundation

/// E-AC-3 (Dolby Digital Plus) helpers: framing a PES payload into access units
/// and reading sample rate / channels / per-frame sample count. E-AC-3 is passed
/// through to the system decoder (`kAudioFormatEnhancedAC3`), so each access unit
/// is one independent substream plus any dependent substreams that follow it.
///
/// E-AC-3 shares AC-3's `0x0B77` syncword but a different header: `frmsiz` gives
/// the frame size directly (no bit-rate table), and `numblkscod` sets the block
/// count (samples = blocks × 256).
enum EAC3 {
    /// Sampling frequency by `fscod` (0–2); `fscod == 3` halves a `fscod2` rate.
    static let sampleRates = [48000, 44100, 32000]
    static let reducedSampleRates = [24000, 22050, 16000]   // fscod == 3, via fscod2

    /// Channel count by `acmod`, before the optional LFE channel.
    private static let channelsByAcmod = [2, 1, 2, 3, 3, 4, 4, 5]

    /// Audio blocks per syncframe by `numblkscod`; each block is 256 samples.
    private static let blocksByCode = [1, 2, 3, 6]

    struct Frame {
        /// One access unit: an independent substream plus its dependent substreams.
        let raw: ArraySlice<UInt8>
    }

    struct Config {
        let sampleRate: Int
        let channels: Int
        let samplesPerFrame: Int
    }

    /// Size in bytes of the syncframe at `i`, or `nil` if the header is invalid.
    private static func frameSize(_ d: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= d.count, d[i] == 0x0B, d[i + 1] == 0x77 else { return nil }
        let frmsiz = (Int(d[i + 2] & 0x07) << 8) | Int(d[i + 3])   // 11 bits
        return (frmsiz + 1) * 2
    }

    /// `strmtyp`: 0 = independent, 1 = dependent, 2 = independent (AC-3 convert).
    private static func streamType(_ d: [UInt8], _ i: Int) -> Int { Int(d[i + 2] >> 6) }

    /// Walks the byte stream and groups syncframes into access units. A unit
    /// begins at an independent substream and absorbs the dependent substreams
    /// that follow, so >5.1 / Atmos streams reach the decoder intact.
    static func frames(in data: [UInt8]) -> [Frame] {
        var out: [Frame] = []
        var i = 0
        let n = data.count
        var unitStart: Int?
        while i + 4 <= n {
            guard let size = frameSize(data, i) else { i += 1; continue }
            guard i + size <= n else { break }
            if streamType(data, i) != 1 {            // independent → unit boundary
                if let s = unitStart { out.append(Frame(raw: data[s..<i])) }
                unitStart = i
            } else if unitStart == nil {             // orphan dependent — start a unit
                unitStart = i
            }
            i += size
        }
        if let s = unitStart, s < i { out.append(Frame(raw: data[s..<i])) }
        return out
    }

    /// Reads the configuration from an access unit (its first, independent frame).
    static func config(from unit: ArraySlice<UInt8>) -> Config? {
        let b = Array(unit)
        guard b.count >= 6, b[0] == 0x0B, b[1] == 0x77 else { return nil }
        // bsi() starts after sync(16) + strmtyp(2) + substreamid(3) + frmsiz(11)
        // = 32 bits, i.e. at byte 4.
        var reader = BitReader(Array(b[4...]))
        guard let fscod = reader.readBits(2) else { return nil }

        let sampleRate: Int
        let blocks: Int
        if fscod == 3 {
            guard let fscod2 = reader.readBits(2), fscod2 < 3 else { return nil }
            sampleRate = reducedSampleRates[Int(fscod2)]
            blocks = 6
        } else {
            guard let numblkscod = reader.readBits(2) else { return nil }
            sampleRate = sampleRates[Int(fscod)]
            blocks = blocksByCode[Int(numblkscod)]
        }
        guard let acmod = reader.readBits(3), let lfeon = reader.readBits(1) else { return nil }

        let channels = channelsByAcmod[Int(acmod)] + Int(lfeon)
        return Config(sampleRate: sampleRate, channels: channels, samplesPerFrame: blocks * 256)
    }
}
