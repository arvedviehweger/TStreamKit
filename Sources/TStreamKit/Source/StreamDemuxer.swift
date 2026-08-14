import Foundation

/// Turns a byte stream of one container format into media. Implementations are
/// fed by `HTTPMediaSource` and know nothing about the network.
///
/// The interface is push-shaped because that is how `URLSession` delivers.
/// libavformat wants to pull instead, so the libavformat implementation buffers
/// what it is handed and lets its own read callback drain that buffer.
protocol StreamDemuxer: AnyObject {
    var output: StreamDemuxerOutput? { get set }

    func consume(_ data: Data)
    /// Drop buffered state so the demuxer resyncs. Called after a seek.
    func reset()
    /// End of stream: emit anything still held back.
    func finish()
    /// Release resources. Nothing is emitted afterwards.
    func stop()
}

extension StreamDemuxer {
    func stop() {}
}

/// Shape of a single pixel, as a container describes it. Only carried for codecs
/// that cannot signal it themselves: VP8 has no field for an aspect ratio, so for
/// anamorphic WebM the container is the only place the picture's real shape is
/// written down. H.264, HEVC and MPEG-2 put it in the bitstream and are
/// unaffected, as is MPEG-TS.
struct PixelAspect: Equatable, Sendable {
    let numerator: Int32
    let denominator: Int32

    init?(numerator: Int32, denominator: Int32) {
        guard numerator > 0, denominator > 0 else { return nil }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// A square pixel needs no correction, so it is worth nothing to pass on.
    var isSquare: Bool { numerator == denominator }
}

/// What a `StreamDemuxer` emits. Timestamps are 90 kHz for every container.
protocol StreamDemuxerOutput: AnyObject {
    /// Reported before any video packet when the container describes its video
    /// out of band. `extradata` is the codec setup record (avcC, hvcC, VP8
    /// CodecPrivate). MPEG-TS carries this in the stream itself and never calls
    /// this, which is what keeps its decode path unchanged.
    func demuxerDidParseVideoFormat(_ codec: VideoCodec, extradata: Data?, pixelAspect: PixelAspect?)
    func demuxerDidProduceVideo(_ data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64)
    func demuxerDidParseAudioFormat(_ format: AudioFormat)
    func demuxerDidProduceAudio(_ unit: AccessUnit)
    func demuxerDidFail(_ error: TStreamError)
}

/// MPEG-TS via the hand-written parser and demuxer. This is the tuned path for
/// DVB broadcast: PAT/PMT handling, DVB AC-3 descriptors, PAFF field pairing and
/// MP2 transcoding all live behind it, so TS never goes through libavformat.
final class TSStreamDemuxer: StreamDemuxer {
    weak var output: StreamDemuxerOutput?

    private let parser = TSPacketParser()
    private let demuxer = TSDemuxer()

    init() {
        demuxer.delegate = self
        // The player decodes video with libavcodec, which does its own NAL and
        // frame assembly, so we never need parsed access units.
        demuxer.rawVideoMode = true
    }

    func consume(_ data: Data) {
        for packet in parser.push(data) { demuxer.consume(packet) }
    }

    func reset() {
        parser.reset()
        demuxer.reset()
    }

    func finish() {
        demuxer.flush()
    }
}

extension TSStreamDemuxer: TSDemuxerDelegate {
    func demuxer(_ d: TSDemuxer, didProduceRawVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        output?.demuxerDidProduceVideo(data, codec: codec, pts: pts, dts: dts)
    }
    func demuxer(_ d: TSDemuxer, didParseAudioFormat format: AudioFormat) {
        output?.demuxerDidParseAudioFormat(format)
    }
    func demuxer(_ d: TSDemuxer, didProduceAudio unit: AccessUnit) {
        output?.demuxerDidProduceAudio(unit)
    }
    func demuxer(_ d: TSDemuxer, didFail error: TStreamError) {
        output?.demuxerDidFail(error)
    }
}
