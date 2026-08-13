import AudioToolbox
import CoreMedia
import Foundation

/// Describes audio to Core Audio.
///
/// Building a description validates almost nothing:
/// `CMAudioFormatDescriptionCreate` returns one for configurations the codec
/// later refuses, and that refusal surfaces deep inside the renderer as silence
/// rather than as an error anyone can catch.
enum CoreAudioSupport {

    static func formatDescription(for format: AudioFormat) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Float64(format.sampleRate)
        asbd.mChannelsPerFrame = UInt32(max(format.channels, 1))
        // AAC/MP2 use an elementary stream descriptor as the magic cookie; AC-3
        // takes none (the `dac3` box is MP4-only and is not a Core Audio cookie).
        var cookie: [UInt8] = []
        switch format.codec {
        case .pcm:
            // Already decoded, interleaved signed 16-bit. One frame per packet,
            // so the renderer can take any number of them at once.
            let bytesPerFrame = UInt32(2 * max(format.channels, 1))
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            asbd.mBitsPerChannel = 16
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = bytesPerFrame
            asbd.mBytesPerPacket = bytesPerFrame
        case .ac3:
            asbd.mFormatID = kAudioFormatAC3
            asbd.mFramesPerPacket = UInt32(format.samplesPerFrame)   // 1536
        case .eac3:
            asbd.mFormatID = kAudioFormatEnhancedAC3
            asbd.mFramesPerPacket = UInt32(format.samplesPerFrame)   // blocks × 256
        case .aac, .mp2:
            // Which AAC this is comes from the config, not from us. Claiming
            // plain AAC-LC for anything else is refused as an unmatched object
            // type and the stream plays silently.
            let config = AudioSpecificConfig(parsing: format.decoderConfig)
            asbd.mFormatID = config?.coreAudioFormatID ?? kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = UInt32(config?.framesPerPacket ?? 1024)
            if let config {
                // The config wins where it disagrees with the container, which
                // it does for HE-AAC: the container reports the output rate and
                // the core runs at half of it.
                asbd.mSampleRate = Float64(config.sampleRate)
                if config.channels > 0 { asbd.mChannelsPerFrame = UInt32(config.channels) }
            }
            cookie = ElementaryStream.descriptor(audioSpecificConfig: format.decoderConfig)
        }
        var desc: CMAudioFormatDescription?
        _ = cookie.withUnsafeBufferPointer { c in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: c.count, magicCookie: c.baseAddress,
                extensions: nil, formatDescriptionOut: &desc)
        }
        return desc
    }
}
