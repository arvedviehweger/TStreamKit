import AudioToolbox
import Foundation

/// The parts of an AudioSpecificConfig that decide how an AAC decoder has to be
/// set up. Containers carry this as codec private data.
///
/// It has to be read rather than assumed: declaring AAC-LC for a stream whose
/// config says otherwise is refused with `unmatched audio object type`, and the
/// stream then plays silently.
struct AudioSpecificConfig {
    /// Audio object type from ISO/IEC 14496-3. 2 is AAC-LC, 5 is HE-AAC and 29
    /// is HE-AAC v2.
    let objectType: Int
    /// Output rate. For HE-AAC this is the extension rate, twice the core rate.
    let sampleRate: Int
    /// Zero when the config defers channels to a program config element.
    let channels: Int

    /// Sampling frequency by index; 15 means an explicit rate follows.
    private static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000,
                                      24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Channel count by configuration; 0 defers to a program config element.
    private static let channelCounts = [0, 1, 2, 3, 4, 5, 6, 8]

    init?(parsing data: Data) {
        var reader = BitReader([UInt8](data))
        guard let type = Self.readObjectType(&reader),
              var rate = Self.readSampleRate(&reader),
              let channelConfig = reader.readBits(4).map(Int.init) else { return nil }

        // Explicit SBR or PS signalling puts the output rate and the core
        // object type after the channel configuration.
        if type == 5 || type == 29 {
            guard let extensionRate = Self.readSampleRate(&reader),
                  Self.readObjectType(&reader) != nil else { return nil }
            rate = extensionRate
        }

        guard rate > 0, channelConfig < Self.channelCounts.count else { return nil }
        objectType = type
        sampleRate = rate
        channels = Self.channelCounts[channelConfig]
    }

    private static func readObjectType(_ reader: inout BitReader) -> Int? {
        guard let type = reader.readBits(5).map(Int.init) else { return nil }
        guard type == 31 else { return type }
        guard let extended = reader.readBits(6).map(Int.init) else { return nil }
        return extended + 32
    }

    private static func readSampleRate(_ reader: inout BitReader) -> Int? {
        guard let index = reader.readBits(4).map(Int.init) else { return nil }
        guard index == 15 else {
            return index < sampleRates.count ? sampleRates[index] : nil
        }
        return reader.readBits(24).map(Int.init)
    }

    /// Core Audio picks the AAC variant by format id, not by a flag.
    var coreAudioFormatID: AudioFormatID {
        switch objectType {
        case 5:  return kAudioFormatMPEG4AAC_HE
        case 23: return kAudioFormatMPEG4AAC_LD
        case 29: return kAudioFormatMPEG4AAC_HE_V2
        case 39: return kAudioFormatMPEG4AAC_ELD
        default: return kAudioFormatMPEG4AAC
        }
    }

    /// Spectral band replication doubles the samples a packet decodes to.
    var framesPerPacket: Int {
        switch objectType {
        case 5, 29: return 2048
        case 23, 39: return 512
        default: return 1024
        }
    }
}
