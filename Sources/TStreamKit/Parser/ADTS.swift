import Foundation

/// AAC-in-ADTS helpers: framing a PES payload into raw AAC frames and deriving
/// the AudioSpecificConfig used in the fMP4 `esds` box.
enum ADTS {
    /// Sampling frequencies indexed by `sampling_frequency_index`.
    static let sampleRates: [Int] = [
        96000, 88200, 64000, 48000, 44100, 32000,
        24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ]

    struct Frame {
        let raw: ArraySlice<UInt8>      // AAC payload without the ADTS header
        let sampleRateIndex: Int
        let channelConfig: Int
        let profile: Int                // ADTS profile (= audioObjectType - 1)
    }

    struct Config {
        let sampleRate: Int
        let channels: Int
        let audioSpecificConfig: Data
    }

    /// Walks an ADTS byte stream and yields each contained AAC frame.
    static func frames(in data: [UInt8]) -> [Frame] {
        var frames: [Frame] = []
        var i = 0
        let n = data.count
        while i + 7 <= n {
            // Syncword: 0xFFF (12 bits).
            guard data[i] == 0xFF, (data[i + 1] & 0xF0) == 0xF0 else {
                i += 1
                continue
            }
            let protectionAbsent = data[i + 1] & 0x01
            let profile = Int((data[i + 2] & 0xC0) >> 6)
            let sampleRateIndex = Int((data[i + 2] & 0x3C) >> 2)
            let channelConfig = Int(((data[i + 2] & 0x01) << 2) | ((data[i + 3] & 0xC0) >> 6))
            let frameLength = (Int(data[i + 3] & 0x03) << 11)
                | (Int(data[i + 4]) << 3)
                | (Int(data[i + 5] & 0xE0) >> 5)

            guard frameLength >= 7, i + frameLength <= n else { break }

            let headerLength = protectionAbsent == 1 ? 7 : 9
            let payloadStart = i + headerLength
            let payloadEnd = i + frameLength
            if payloadStart < payloadEnd, sampleRateIndex < sampleRates.count {
                frames.append(Frame(raw: data[payloadStart..<payloadEnd],
                                    sampleRateIndex: sampleRateIndex,
                                    channelConfig: channelConfig,
                                    profile: profile))
            }
            i += frameLength
        }
        return frames
    }

    /// Builds the 2-byte AudioSpecificConfig for an AAC frame.
    static func config(from frame: Frame) -> Config {
        let audioObjectType = frame.profile + 1            // ADTS profile is AOT-1
        let sampleRate = sampleRates[safe: frame.sampleRateIndex] ?? 44100
        let channels = frame.channelConfig

        var asc = Data(count: 2)
        asc[0] = UInt8((audioObjectType << 3) | ((frame.sampleRateIndex >> 1) & 0x07))
        asc[1] = UInt8(((frame.sampleRateIndex & 0x01) << 7) | ((frame.channelConfig & 0x0F) << 3))
        return Config(sampleRate: sampleRate, channels: channels, audioSpecificConfig: asc)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
