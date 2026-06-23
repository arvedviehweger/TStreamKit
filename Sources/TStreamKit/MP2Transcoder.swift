import AudioToolbox
import CKJMP2
import Foundation

/// Transcodes an MPEG-1/2 Audio Layer II (MP2) elementary stream to AAC so it
/// can be muxed into fMP4 and played by AVPlayer — iOS has no Layer II decoder
/// in the AVPlayer path, so MP2 cannot be passed through.
///
/// Pipeline: kjmp2 decodes each MP2 frame to 1152 interleaved-stereo Int16 PCM
/// samples; an `AudioConverter` re-encodes the PCM to AAC-LC (1024 samples per
/// packet). Confined to the demuxer's serial queue (kjmp2 is not thread-safe).
final class MP2Transcoder {
    /// Emitted once, when the output AAC format is known.
    var onFormat: ((AudioFormat) -> Void)?
    /// Emitted per encoded AAC frame: (raw AAC packet, PTS in 90 kHz).
    var onAAC: ((Data, UInt64) -> Void)?

    private let decoder = UnsafeMutablePointer<kjmp2_context_t>.allocate(capacity: 1)
    private var converter: AudioConverterRef?
    private var sampleRate = 0
    private let outChannels = 2          // kjmp2 always outputs stereo
    private var didEmitFormat = false

    /// Interleaved-stereo Int16 PCM awaiting encode.
    private var pcmQueue: [Int16] = []
    /// Bytes of a frame split across PES boundaries, carried to the next PES.
    private var residual: [UInt8] = []
    /// 90 kHz presentation time of the first decoded sample.
    private var basePTS: UInt64?
    /// AAC sample frames emitted so far (for drift-free output timestamps).
    private var outputSampleCount: UInt64 = 0

    // Scratch shared with the AudioConverter input callback during a drain.
    private var inputBase: UnsafePointer<Int16>?
    private var inputFrameTotal = 0
    private var inputCursor = 0

    init() { kjmp2_init(decoder) }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        decoder.deallocate()
    }

    /// Consumes the MP2 elementary bytes from one PES (with that PES's PTS),
    /// decoding every complete frame and encoding the result to AAC.
    func consume(_ elementary: [UInt8], pts: UInt64) {
        var data = residual
        data.append(contentsOf: elementary)
        residual = []

        var i = 0
        while true {
            guard let sync = MPEGAudio.nextSync(data, from: i) else { break }
            guard let header = MPEGAudio.parseHeader(data, sync) else { i = sync + 1; continue }
            guard sync + header.frameLength <= data.count else {
                // Incomplete trailing frame — keep it for the next PES.
                residual = Array(data[sync...])
                break
            }
            if basePTS == nil { basePTS = pts }
            setupIfNeeded(sampleRate: header.sampleRate)
            decode(Array(data[sync..<(sync + header.frameLength)]))
            i = sync + header.frameLength
        }
        drain()
    }

    // MARK: - Decode

    private func decode(_ frame: [UInt8]) {
        var pcm = [Int16](repeating: 0, count: 1152 * 2) // always stereo
        frame.withUnsafeBufferPointer { fb in
            pcm.withUnsafeMutableBufferPointer { pb in
                _ = kjmp2_decode_frame(decoder, fb.baseAddress, pb.baseAddress)
            }
        }
        pcmQueue.append(contentsOf: pcm)
    }

    // MARK: - Encode

    private func setupIfNeeded(sampleRate sr: Int) {
        guard converter == nil else { return }
        sampleRate = sr

        var inFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sr),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * outChannels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * outChannels),
            mChannelsPerFrame: UInt32(outChannels),
            mBitsPerChannel: 16,
            mReserved: 0)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sr),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(outChannels),
            mBitsPerChannel: 0,
            mReserved: 0)

        var conv: AudioConverterRef?
        guard AudioConverterNew(&inFormat, &outFormat, &conv) == noErr, let conv else { return }
        converter = conv

        var bitrate: UInt32 = 128_000
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)

        if !didEmitFormat {
            didEmitFormat = true
            onFormat?(AudioFormat(codec: .aac,
                                  sampleRate: sr,
                                  channels: outChannels,
                                  samplesPerFrame: 1024,
                                  decoderConfig: Self.audioSpecificConfig(sampleRate: sr, channels: outChannels)))
        }
    }

    private func drain() {
        guard let converter else { return }
        let framesPerPacket = 1024
        let maxAACBytes = 1536

        pcmQueue.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<Int16>) in
            inputBase = buf.baseAddress
            inputFrameTotal = pcmQueue.count / outChannels
            inputCursor = 0

            let outData = UnsafeMutableRawPointer.allocate(byteCount: maxAACBytes, alignment: 1)
            defer { outData.deallocate() }

            while inputFrameTotal - inputCursor >= framesPerPacket {
                var ioPackets: UInt32 = 1
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(outChannels),
                                          mDataByteSize: UInt32(maxAACBytes),
                                          mData: outData))
                let status = AudioConverterFillComplexBuffer(
                    converter, Self.inputProc,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &ioPackets, &abl, nil)
                guard status == noErr, ioPackets == 1 else { break }

                let size = Int(abl.mBuffers.mDataByteSize)
                guard size > 0 else { break }
                let aac = Data(bytes: outData, count: size)
                let pts = (basePTS ?? 0) &+ outputSampleCount &* 90_000 / UInt64(max(sampleRate, 1))
                onAAC?(aac, pts)
                outputSampleCount &+= UInt64(framesPerPacket)
            }
            inputBase = nil
        }

        if inputCursor > 0 {
            pcmQueue.removeFirst(inputCursor * outChannels)
        }
        inputCursor = 0
    }

    /// Supplies queued PCM to the encoder. No captures, so it bridges to a C
    /// function pointer; the transcoder is recovered from `inUserData`.
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, inUserData in
        guard let inUserData else { ioNumberDataPackets.pointee = 0; return noErr }
        let me = Unmanaged<MP2Transcoder>.fromOpaque(inUserData).takeUnretainedValue()

        let framesLeft = me.inputFrameTotal - me.inputCursor
        let n = min(framesLeft, Int(ioNumberDataPackets.pointee))
        guard n > 0, let base = me.inputBase else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let ptr = UnsafeMutableRawPointer(mutating: base.advanced(by: me.inputCursor * me.outChannels))
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = UInt32(me.outChannels)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(n * me.outChannels * 2)
        ioData.pointee.mBuffers.mData = ptr
        me.inputCursor += n
        ioNumberDataPackets.pointee = UInt32(n)
        return noErr
    }

    // MARK: - Helpers

    private static let ascSampleRateIndex: [Int: Int] = [
        96000: 0, 88200: 1, 64000: 2, 48000: 3, 44100: 4, 32000: 5,
        24000: 6, 22050: 7, 16000: 8, 12000: 9, 11025: 10, 8000: 11,
    ]

    /// Two-byte AudioSpecificConfig for AAC-LC (object type 2), matching the
    /// `ADTS.config` layout the muxer's `esds` expects.
    static func audioSpecificConfig(sampleRate: Int, channels: Int) -> Data {
        let srIndex = ascSampleRateIndex[sampleRate] ?? 4
        let objectType = 2
        let byte0 = UInt8((objectType << 3) | (srIndex >> 1))
        let byte1 = UInt8(((srIndex & 1) << 7) | (channels << 3))
        return Data([byte0, byte1])
    }
}
