import Foundation

/// MPEG-4 elementary stream descriptor, the form Core Audio expects an AAC
/// decoder configuration to arrive in.
///
/// Containers store the bare AudioSpecificConfig, and handing that over as the
/// magic cookie is rejected by the codec. Nothing reports it at the time:
/// `CMAudioFormatDescriptionCreate` still returns a description, and the failure
/// only surfaces later as a decoder that cannot start, so a stream plays its
/// video and stays silent.
enum ElementaryStream {
    /// Tag values from ISO/IEC 14496-1.
    private enum Tag {
        static let stream: UInt8 = 0x03
        static let decoderConfig: UInt8 = 0x04
        static let decoderSpecificInfo: UInt8 = 0x05
        static let syncLayer: UInt8 = 0x06
    }

    /// MPEG-4 audio, carried on an audio stream.
    private static let mpeg4Audio: UInt8 = 0x40
    private static let audioStream: UInt8 = 0x15

    /// Longest config this can describe. Every descriptor length here is a
    /// single byte, which caps the payload; a real config is a few bytes, so
    /// the limit only guards against nonsense.
    static let maximumConfigSize = 64

    /// Wraps an AudioSpecificConfig for use as an AAC magic cookie. Returns
    /// nothing for a config it cannot describe, which is safe: an empty cookie
    /// still plays plain AAC-LC, where the sample rate and channel count in the
    /// stream description are enough.
    static func descriptor(audioSpecificConfig config: Data) -> [UInt8] {
        guard (1...maximumConfigSize).contains(config.count) else { return [] }

        // The buffer size and the two bitrates stay zero: a decoder does not
        // need them, and for a live stream we do not know them.
        var decoderConfig: [UInt8] = [mpeg4Audio, audioStream,
                                      0, 0, 0,
                                      0, 0, 0, 0,
                                      0, 0, 0, 0]
        decoderConfig += [Tag.decoderSpecificInfo, UInt8(config.count)] + config

        var stream: [UInt8] = [0x00, 0x00, 0x00]    // stream id and flags
        stream += [Tag.decoderConfig, UInt8(decoderConfig.count)] + decoderConfig
        stream += [Tag.syncLayer, 0x01, 0x02]       // predefined: none
        return [Tag.stream, UInt8(stream.count)] + stream
    }
}
