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
    private var paused = false

    /// Byte offset of the current request (0 for the initial, non-ranged fetch).
    private var rangeOffset: Int64 = 0
    /// Total length of the resource in bytes, learned from the first response.
    /// Used to translate a seek fraction into a byte offset. 0 until known.
    private(set) var totalBytes: Int64 = 0

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
            self.startRequest(rangeOffset: 0)
            TStreamDiagnostics.log("source: started fetching \(self.httpURL.absoluteString)")
        }
    }

    /// Seeks to a byte offset by cancelling the current download, resetting the
    /// parser/demuxer (so they resync to the next TS packet and re-acquire
    /// PAT/PMT), and re-issuing the request with an HTTP `Range` header. The
    /// completion fires on the source queue *after* the new request has started
    /// — the player uses it as a barrier to discard any in-flight pre-seek data.
    func seek(toByteOffset offset: Int64, completion: @escaping () -> Void) {
        queue.async {
            guard !self.stopped else { return }
            self.dataTask?.cancel()
            self.dataTask = nil
            self.parser.reset()
            self.demuxer.reset()
            self.paused = false
            self.startRequest(rangeOffset: max(0, offset))
            TStreamDiagnostics.log("source: seek to byte \(offset)")
            completion()
        }
    }

    /// Issues the HTTP request, adding a `Range` header when seeking into the
    /// resource. Must be called on `queue`.
    private func startRequest(rangeOffset: Int64) {
        guard self.failure == nil, !self.stopped else { return }
        self.rangeOffset = rangeOffset
        var request = URLRequest(url: self.httpURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (field, value) in self.httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if rangeOffset > 0 {
            request.setValue("bytes=\(rangeOffset)-", forHTTPHeaderField: "Range")
        }
        let task = self.session.dataTask(with: request)
        self.dataTask = task
        task.resume()
    }

    /// Backpressure: stop reading from the socket. The TCP receive window fills
    /// and tvheadend stops sending — without this a recording (served as fast as
    /// the connection allows, unlike a rate-limited live stream) floods the
    /// decoder and the decoded-frame queues grow until the app is OOM-killed.
    func pause() {
        queue.async {
            guard !self.stopped, !self.paused, let task = self.dataTask else { return }
            self.paused = true
            task.suspend()
        }
    }

    /// Resume reading once the player has drained its buffer back down.
    func resume() {
        queue.async {
            guard !self.stopped, self.paused, let task = self.dataTask else { return }
            self.paused = false
            task.resume()
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
            // Drop bytes from a task we've already replaced (e.g. after a seek).
            guard self.failure == nil, !self.stopped, dataTask == self.dataTask else { return }
            for packet in self.parser.push(data) { self.demuxer.consume(packet) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 200 (full) and 206 (partial, from a Range request) are both fine.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            queue.async { [weak self] in self?.fail(.transport("HTTP \(http.statusCode)")) }
            completionHandler(.cancel)
            return
        }
        // expectedContentLength is the length of *this* response: for a ranged
        // request that's the remainder, so add the offset to get the total.
        let expected = response.expectedContentLength
        queue.async { [weak self] in
            guard let self else { return }
            if expected > 0 { self.totalBytes = self.rangeOffset + expected }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            // Ignore completion of a task we've already replaced (seek/cancel).
            guard !self.stopped, task == self.dataTask else { return }
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
