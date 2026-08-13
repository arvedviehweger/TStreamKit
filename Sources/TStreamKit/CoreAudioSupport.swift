import AudioToolbox
import CoreMedia
import Foundation

/// Describes audio to Core Audio, and answers whether Core Audio can actually
/// take it.
///
/// The second question has to be asked out loud. Building a format description
/// validates almost nothing: `CMAudioFormatDescriptionCreate` returns a
/// description for configurations the codec later refuses, and that refusal
/// surfaces deep inside the renderer as silence rather than as an error anyone
/// can catch. Opening a decoder is the only honest test.
enum CoreAudioSupport {

    /// Whether the system decoder can be set up for this format.
    ///
    /// Worth asking for AAC, where support depends on the profile: AAC Main is
    /// refused outright, so a stream carrying it has to be decoded elsewhere.
    static func canDecode(_ format: AudioFormat) -> Bool {
        guard let description = formatDescription(for: format),
              var input = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return false }

        var output = AudioStreamBasicDescription()
        output.mSampleRate = input.mSampleRate
        output.mFormatID = kAudioFormatLinearPCM
        output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        output.mChannelsPerFrame = max(input.mChannelsPerFrame, 1)
        output.mBitsPerChannel = 16
        output.mFramesPerPacket = 1
        output.mBytesPerFrame = 2 * output.mChannelsPerFrame
        output.mBytesPerPacket = output.mBytesPerFrame

        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr,
              let converter else { return false }
        defer { AudioConverterDispose(converter) }

        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size),
              size > 0 else { return true }
        return AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                         UInt32(size), cookie) == noErr
    }

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
