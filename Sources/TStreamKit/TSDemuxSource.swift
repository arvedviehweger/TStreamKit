import Foundation

/// Fetches an HTTP MPEG-TS stream and runs it through the parser → demuxer on a
/// serial queue, forwarding decoded access units to `delegate`. This is the
/// network + parsing half of the pipeline without any muxing — used by the
/// `AVSampleBuffer`-based player, which decodes the access units directly and
/// controls its own VideoToolbox session (so it can recover from the open-GOP /
/// non-IDR broadcast streams that derail AVPlayer's HLS decode path).
///
/// All delegate callbacks are delivered on the private `queue`.
final class TSDemuxSource: NSObject {
    weak var delegate: TSDemuxerDelegate?
    var onError: ((TStreamError) -> Void)?

    private let httpURL: URL
    private let httpHeaders: [String: String]
    private let configuration: URLSessionConfiguration
    private let queue = DispatchQueue(label: "com.tstream.source")
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    private var dataTask: URLSessionDataTask?
    private let parser = TSPacketParser()
    private let demuxer = TSDemuxer()
    private var failure: TStreamError?
    private var stopped = false

    /// Forward raw video PES (for libavcodec) instead of parsed access units.
    var rawVideoMode: Bool {
        get { demuxer.rawVideoMode }
        set { demuxer.rawVideoMode = newValue }
    }

    init(httpURL: URL, headers: [String: String] = [:], configuration: URLSessionConfiguration = .default) {
        self.httpURL = httpURL
        self.httpHeaders = headers
        self.configuration = configuration
        super.init()
        demuxer.delegate = self
    }

    func start() {
        queue.async {
            guard self.dataTask == nil, self.failure == nil, !self.stopped else { return }
            var request = URLRequest(url: self.httpURL)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (field, value) in self.httpHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
            let task = self.session.dataTask(with: request)
            self.dataTask = task
            task.resume()
            TStreamDiagnostics.log("source: started fetching \(self.httpURL.absoluteString)")
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.delegate = nil
            self.onError = nil
            self.dataTask?.cancel()
            self.dataTask = nil
            // URLSession holds a strong reference to its delegate until it is
            // invalidated, so cancel it on the source queue before any completion
            // callback can flush buffered PES after stop().
            self.session.invalidateAndCancel()
        }
    }

    private func fail(_ error: TStreamError) {
        guard failure == nil, !stopped else { return }
        failure = error
        onError?(error)
    }
}

extension TSDemuxSource: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            guard self.failure == nil, !self.stopped else { return }
            for packet in self.parser.push(data) { self.demuxer.consume(packet) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            queue.async { [weak self] in self?.fail(.transport("HTTP \(http.statusCode)")) }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard !self.stopped else { return }
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.fail(.transport(error.localizedDescription))
                return
            }
            self.demuxer.flush()
        }
    }
}

// Forward the demuxer's output to the player.
extension TSDemuxSource: TSDemuxerDelegate {
    func demuxer(_ d: TSDemuxer, didParseVideoFormat format: VideoFormat) { delegate?.demuxer(d, didParseVideoFormat: format) }
    func demuxer(_ d: TSDemuxer, didParseAudioFormat format: AudioFormat) { delegate?.demuxer(d, didParseAudioFormat: format) }
    func demuxer(_ d: TSDemuxer, didProduceVideo unit: AccessUnit) { delegate?.demuxer(d, didProduceVideo: unit) }
    func demuxer(_ d: TSDemuxer, didProduceAudio unit: AccessUnit) { delegate?.demuxer(d, didProduceAudio: unit) }
    func demuxer(_ d: TSDemuxer, didFail error: TStreamError) { delegate?.demuxer(d, didFail: error) }
    func demuxer(_ d: TSDemuxer, didIdentifyStreamsHasVideo v: Bool, hasAudio a: Bool) {
        delegate?.demuxer(d, didIdentifyStreamsHasVideo: v, hasAudio: a)
    }
    func demuxer(_ d: TSDemuxer, didProduceRawVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        delegate?.demuxer(d, didProduceRawVideo: data, codec: codec, pts: pts, dts: dts)
    }
}
