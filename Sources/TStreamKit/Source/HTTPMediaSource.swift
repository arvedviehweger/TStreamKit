import Foundation

/// The stream source the player uses for anything served over HTTP: fetches
/// the bytes and hands them to the shared container pipeline.
///
/// All delegate callbacks are delivered on the private `queue`.
final class HTTPMediaSource: MediaSource {
    weak var delegate: MediaSourceDelegate?
    var onError: ((TStreamError) -> Void)?

    private let queue = DispatchQueue(label: "com.tstream.source")
    private let stream: HTTPByteStream
    private let pipeline = ContainerPipeline()
    private var failed = false
    private var stopped = false

    init(url: URL, headers: [String: String] = [:], credential: URLCredential? = nil,
         configuration: URLSessionConfiguration = .default) {
        self.stream = HTTPByteStream(url: url, headers: headers, credential: credential,
                                     queue: queue, configuration: configuration)
        pipeline.output = self
        pipeline.onFail = { [weak self] error in self?.fail(error) }
        stream.onData = { [weak self] data in self?.ingest(data) }
        stream.onFinish = { [weak self] in self?.pipeline.finish() }
        stream.onReset = { [weak self] in self?.pipeline.reset() }
        stream.onError = { [weak self] error in self?.fail(error) }
    }

    func start() { stream.start() }
    func pause() { stream.pause() }
    func resume() { stream.resume() }

    func stop() {
        stream.stop()
        queue.async {
            self.stopped = true
            self.delegate = nil
            self.onError = nil
            self.pipeline.stop()
        }
    }

    /// Only a finite resource (a recording) has a length to seek within, and a
    /// container we never identified can't be seeked into either.
    var isSeekable: Bool { stream.length > 0 && pipeline.isIdentified }

    /// Seeks by byte offset, which is what the sources we support can actually
    /// do: TS resyncs to the next packet from anywhere, and the libavformat path
    /// restarts its probe at the new offset. Landing mid-structure is expected,
    /// and decoding resumes at the next keyframe.
    func seek(toFraction fraction: Double, completion: @escaping () -> Void) {
        let total = stream.length
        // The completion must fire on every path: the player holds its decode
        // gate shut until it does, so swallowing it here would freeze playback.
        guard total > 0 else { queue.async(execute: completion); return }
        let clamped = min(max(fraction, 0), 1)
        stream.seek(toByteOffset: Int64(Double(total) * clamped), completion: completion)
    }

    /// On `queue`.
    private func ingest(_ data: Data) {
        guard !stopped, !failed else { return }
        pipeline.consume(data)
    }

    /// On `queue`. Reports once and then goes quiet.
    private func fail(_ error: TStreamError) {
        guard !failed, !stopped else { return }
        failed = true
        TStreamDiagnostics.log("source: failed with \(error.localizedDescription)")
        onError?(error)
        delegate?.mediaSource(self, didFail: error)
    }
}

// Forward the demuxer's output to the player.
extension HTTPMediaSource: StreamDemuxerOutput {
    func demuxerDidParseVideoFormat(_ codec: VideoCodec, extradata: Data?, pixelAspect: PixelAspect?) {
        delegate?.mediaSource(self, didParseVideoFormat: codec, extradata: extradata, pixelAspect: pixelAspect)
    }
    func demuxerDidProduceVideo(_ data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64, isKeyframe: Bool) {
        delegate?.mediaSource(self, didProduceVideo: data, codec: codec, pts: pts, dts: dts,
                              isKeyframe: isKeyframe)
    }
    func demuxerDidDetectAudioOnly() {
        delegate?.mediaSourceDidDetectAudioOnly(self)
    }
    func demuxerDidParseAudioFormat(_ format: AudioFormat) {
        delegate?.mediaSource(self, didParseAudioFormat: format)
    }
    func demuxerDidProduceAudio(_ unit: AccessUnit) {
        delegate?.mediaSource(self, didProduceAudio: unit)
    }
    func demuxerDidFail(_ error: TStreamError) {
        fail(error)
    }
}
