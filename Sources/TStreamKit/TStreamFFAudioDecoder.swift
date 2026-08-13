import Foundation
import CFFVideoDecoder

/// Decodes the audio codecs Core Audio cannot take (Vorbis, Opus) into
/// interleaved signed 16-bit PCM. Everything Core Audio can handle stays
/// compressed and never comes through here.
final class TStreamFFAudioDecoder {
    private let decoder: OpaquePointer

    /// One block of decoded PCM and its 90 kHz presentation time.
    struct DecodedAudio {
        let data: Data
        let frames: Int
        let pts: UInt64
    }

    var sampleRate: Int { Int(cff_audio_sample_rate(decoder)) }
    var channels: Int { Int(cff_audio_channels(decoder)) }

    /// `extradata` is the container's setup record. Vorbis keeps its three setup
    /// headers there and cannot start without them.
    init?(codec: CFFAudioCodec, sampleRate: Int, channels: Int, extradata: Data?) {
        let setup = extradata ?? Data()
        let created = setup.withUnsafeBytes { raw in
            cff_audio_create(codec, Int32(sampleRate), Int32(channels),
                             raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count))
        }
        guard let dec = created else { return nil }
        self.decoder = dec
    }

    deinit { cff_audio_destroy(decoder) }

    /// Feeds one compressed packet and returns whatever PCM it completed.
    func decode(_ data: Data, pts: UInt64) -> [DecodedAudio] {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = cff_audio_feed(decoder, base, Int32(data.count), Int64(pts))
        }

        var blocks: [DecodedAudio] = []
        var frame = CFFAudioFrame()
        while cff_audio_receive(decoder, &frame) == 1 {
            guard let bytes = frame.data, frame.size > 0 else { continue }
            blocks.append(DecodedAudio(data: Data(bytes: bytes, count: Int(frame.size)),
                                       frames: Int(frame.frames),
                                       pts: frame.pts == Int64.min ? pts : UInt64(max(0, frame.pts))))
        }
        return blocks
    }
}
