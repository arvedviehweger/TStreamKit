import Foundation

/// A container-agnostic stream source: fetches the bytes, demuxes them, and
/// hands the player raw video packets plus compressed audio.
///
/// The player only ever needs raw video (libavcodec does its own parsing) and
/// audio it can pass to the system decoder, so nothing here mentions a
/// container. `TSDemuxSource` reads MPEG-TS with the hand-written demuxer;
/// other containers (Matroska/WebM, fMP4) go through libavformat.
///
/// All delegate callbacks are delivered on the source's own private queue.
protocol MediaSource: AnyObject {
    var delegate: MediaSourceDelegate? { get set }
    var onError: ((TStreamError) -> Void)? { get set }

    func start()
    func stop()

    /// Backpressure: stop / resume reading from the network so a fast source
    /// (a recording, served as fast as the link allows) can't outrun the
    /// decoder and exhaust memory.
    func pause()
    func resume()

    /// Whether `seek(toFraction:)` can do anything. False for a live stream,
    /// which has no length to seek within.
    var isSeekable: Bool { get }

    /// Seek to a fraction (0…1) of the stream. Approximate — how the position is
    /// resolved is the source's business (byte offset for TS, index for
    /// libavformat). `completion` fires on the source's queue once the new read
    /// position is live, so the player can discard stale pre-seek data.
    func seek(toFraction fraction: Double, completion: @escaping () -> Void)
}

/// Output of a `MediaSource`. Timestamps are 90 kHz for every source — a
/// container with a different time base rescales before reporting.
protocol MediaSourceDelegate: AnyObject {
    /// The container described its video before any packet arrived. `extradata`
    /// is the codec setup record, which the decoder needs for length-prefixed
    /// H.264 in Matroska and MP4. MPEG-TS carries its parameter sets in the
    /// stream and never calls this.
    func mediaSource(_ source: MediaSource, didParseVideoFormat codec: VideoCodec, extradata: Data?,
                     pixelAspect: PixelAspect?)
    /// One chunk of the video stream. Annex-B bytes to be parsed when no format
    /// was announced, otherwise exactly one already-framed packet.
    func mediaSource(_ source: MediaSource, didProduceVideo data: Data,
                     codec: VideoCodec, pts: UInt64, dts: UInt64)
    func mediaSource(_ source: MediaSource, didParseAudioFormat format: AudioFormat)
    func mediaSource(_ source: MediaSource, didProduceAudio unit: AccessUnit)
    func mediaSource(_ source: MediaSource, didFail error: TStreamError)
}
