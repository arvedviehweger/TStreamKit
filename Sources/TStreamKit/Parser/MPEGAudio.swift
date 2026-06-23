import Foundation

/// MPEG-1/2 Audio (Layer II) frame-header parsing — enough to find frame
/// boundaries and the stream's sample rate / channel count. The actual decode
/// is done by the vendored kjmp2 library; this just frames the elementary
/// stream so complete frames can be handed to it.
enum MPEGAudio {
    struct FrameHeader {
        let sampleRate: Int
        let channels: Int       // 1 = mono, 2 = stereo/joint/dual
        let frameLength: Int    // total bytes incl. the 4-byte header
        let samplesPerFrame: Int
    }

    /// Layer II bitrate tables in kbps, indexed by `bitrate_index` (0 = free,
    /// 15 = invalid). Row 0 = MPEG-1, row 1 = MPEG-2/2.5 (LSF).
    private static let bitratesLayerII: [[Int]] = [
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0],
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
    ]

    /// Sample-rate tables keyed by `version_id` (0 = MPEG-2.5, 2 = MPEG-2,
    /// 3 = MPEG-1), indexed by `sampling_rate_index`.
    private static let sampleRates: [Int: [Int]] = [
        3: [44100, 48000, 32000],
        2: [22050, 24000, 16000],
        0: [11025, 12000, 8000],
    ]

    /// Parses an MPEG audio frame header at `b[offset...]`. Returns nil if the
    /// bytes are not a valid **Layer II** header.
    static func parseHeader(_ b: [UInt8], _ offset: Int) -> FrameHeader? {
        guard offset + 4 <= b.count else { return nil }
        let h1 = b[offset + 1], h2 = b[offset + 2], h3 = b[offset + 3]
        // 11-bit frame sync.
        guard b[offset] == 0xFF, (h1 & 0xE0) == 0xE0 else { return nil }

        let versionId = Int((h1 >> 3) & 0x03)   // 0=2.5, 1=reserved, 2=2, 3=1
        let layer = Int((h1 >> 1) & 0x03)        // 1=III, 2=II, 3=I
        guard versionId != 1, layer == 2 else { return nil }

        let bitrateIndex = Int((h2 >> 4) & 0x0F)
        let sampleRateIndex = Int((h2 >> 2) & 0x03)
        let padding = Int((h2 >> 1) & 0x01)
        let channelMode = Int((h3 >> 6) & 0x03)  // 3 = single channel (mono)

        guard bitrateIndex > 0, bitrateIndex < 15, sampleRateIndex < 3,
              let srTable = sampleRates[versionId] else { return nil }
        let sampleRate = srTable[sampleRateIndex]
        let isLSF = versionId != 3
        let bitrate = bitratesLayerII[isLSF ? 1 : 0][bitrateIndex] * 1000
        guard bitrate > 0, sampleRate > 0 else { return nil }

        // Layer II carries 1152 samples/frame for both MPEG-1 and MPEG-2;
        // frame length = 144 * bitrate / sampleRate + padding.
        let frameLength = (144 * bitrate / sampleRate) + padding
        guard frameLength > 4 else { return nil }

        return FrameHeader(sampleRate: sampleRate,
                           channels: channelMode == 3 ? 1 : 2,
                           frameLength: frameLength,
                           samplesPerFrame: 1152)
    }

    /// Index of the next frame sync (`0xFF Ex`) at or after `offset`, or nil.
    static func nextSync(_ b: [UInt8], from offset: Int) -> Int? {
        var i = max(offset, 0)
        while i + 1 < b.count {
            if b[i] == 0xFF, (b[i + 1] & 0xE0) == 0xE0 { return i }
            i += 1
        }
        return nil
    }
}
