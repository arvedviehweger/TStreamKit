import Foundation

/// The stream source the player uses: fetches over HTTP, works out which
/// container the server sent, and runs the matching demuxer.
///
/// Detection happens on the live connection rather than through a separate
/// probe request. tvheadend starts a transcode session per connection, so
/// opening a second one to sniff would both cost a round trip and leave a
/// stray session behind.
///
/// All delegate callbacks are delivered on the private `queue`.
final class HTTPMediaSource: MediaSource {
    weak var delegate: MediaSourceDelegate?
    var onError: ((TStreamError) -> Void)?

    private let queue = DispatchQueue(label: "com.tstream.source")
    private let stream: HTTPByteStream

    /// Bytes held back until the container is known, then replayed into the
    /// demuxer. Empty once detection has finished.
    private var probeBuffer: [UInt8] = []
    private var format: ContainerFormat?
    private var demuxer: StreamDemuxer?
    private var failed = false
    private var stopped = false

    init(url: URL, headers: [String: String] = [:], configuration: URLSessionConfiguration = .default) {
        self.stream = HTTPByteStream(url: url, headers: headers, queue: queue, configuration: configuration)
        stream.onData = { [weak self] data in self?.ingest(data) }
        stream.onFinish = { [weak self] in self?.demuxer?.finish() }
        stream.onReset = { [weak self] in self?.demuxer?.reset() }
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
            self.demuxer?.stop()
            self.demuxer = nil
            self.probeBuffer.removeAll()
        }
    }

    /// Only a finite resource (a recording) has a length to seek within, and a
    /// container we never identified can't be seeked into either.
    var isSeekable: Bool { stream.length > 0 && format != nil }

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

    // MARK: - Detection

    /// On `queue`. Buffers until the container is known, then hands everything
    /// to the demuxer and gets out of the way.
    private func ingest(_ data: Data) {
        guard !stopped, !failed else { return }

        if let demuxer {
            demuxer.consume(data)
            return
        }

        probeBuffer.append(contentsOf: data)
        guard let detected = ContainerFormat.detect(probeBuffer) else {
            if probeBuffer.count >= ContainerFormat.probeLimit {
                fail(.demux("could not identify the container in the first \(probeBuffer.count) bytes"))
            }
            return
        }

        guard let made = makeDemuxer(for: detected) else {
            fail(.unsupportedCodec("\(describe(detected)) streams are not supported yet"))
            return
        }
        made.output = self
        format = detected
        demuxer = made
        TStreamDiagnostics.log("source: detected \(describe(detected)) container")

        let buffered = Data(probeBuffer)
        probeBuffer.removeAll(keepingCapacity: false)
        made.consume(buffered)
    }

    private func makeDemuxer(for format: ContainerFormat) -> StreamDemuxer? {
        switch format {
        case .mpegTS: return TSStreamDemuxer()
        case .matroska, .mp4: return nil    // libavformat path, not wired up yet
        }
    }

    private func describe(_ format: ContainerFormat) -> String {
        switch format {
        case .mpegTS: return "MPEG-TS"
        case .matroska: return "Matroska/WebM"
        case .mp4: return "MP4"
        }
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
    func demuxerDidProduceVideo(_ data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        delegate?.mediaSource(self, didProduceVideo: data, codec: codec, pts: pts, dts: dts)
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
