import Foundation

/// Fetches an HTTP resource and hands the bytes to a consumer, with the two
/// controls a media pipeline needs: backpressure, and restarting at a byte
/// offset for seeking.
///
/// This is the container-agnostic half of a source. What the bytes *mean* is
/// the demuxer's business, so both the hand-written TS path and the libavformat
/// path share this.
///
/// Every callback is delivered on the `queue` handed to `init`.
final class HTTPByteStream: NSObject {
    /// Freshly received bytes, in order.
    var onData: ((Data) -> Void)?
    /// The stream ended cleanly. Not called for a cancelled or replaced request.
    var onFinish: (() -> Void)?
    var onError: ((TStreamError) -> Void)?
    /// A new request has started at a byte offset, so anything buffered from
    /// before is stale. Fires before the first `onData` of the new segment.
    var onReset: (() -> Void)?

    private let httpURL: URL
    private let httpHeaders: [String: String]
    private let queue: DispatchQueue
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    private let configuration: URLSessionConfiguration
    private var dataTask: URLSessionDataTask?
    private var failure: TStreamError?
    private var stopped = false
    private var paused = false

    /// Byte offset of the current request (0 for the initial, non-ranged fetch).
    private var rangeOffset: Int64 = 0

    /// Total length of the resource, learned from the first response. 0 until
    /// known, and a live stream never reports one. Written on `queue` but read
    /// from anywhere, so it takes a lock rather than a `queue.sync` (which would
    /// deadlock if ever read from `queue` itself).
    private var totalBytes: Int64 = 0
    private let totalBytesLock = NSLock()

    var length: Int64 {
        totalBytesLock.lock(); defer { totalBytesLock.unlock() }; return totalBytes
    }

    private func setLength(_ value: Int64) {
        totalBytesLock.lock(); totalBytes = value; totalBytesLock.unlock()
    }

    /// The response `Content-Type`, when the server sent one. Only a hint for
    /// container detection; the magic bytes are the authority. Confined to
    /// `queue`, like the rest of the response handling.
    private(set) var contentType: String?

    init(url: URL,
         headers: [String: String] = [:],
         queue: DispatchQueue,
         configuration: URLSessionConfiguration = .default) {
        self.httpURL = url
        self.httpHeaders = headers
        self.queue = queue
        self.configuration = configuration
        super.init()
    }

    func start() {
        queue.async {
            guard self.dataTask == nil, self.failure == nil, !self.stopped else { return }
            self.startRequest(rangeOffset: 0)
            TStreamDiagnostics.log("source: started fetching \(self.httpURL.absoluteString)")
        }
    }

    /// Restarts the download at `offset` using an HTTP `Range` header. The
    /// completion fires on `queue` after the new request has started, so the
    /// caller can use it as a barrier against in-flight pre-seek data.
    func seek(toByteOffset offset: Int64, completion: @escaping () -> Void) {
        queue.async {
            guard !self.stopped else { completion(); return }
            self.dataTask?.cancel()
            self.dataTask = nil
            self.paused = false
            self.onReset?()
            self.startRequest(rangeOffset: max(0, offset))
            TStreamDiagnostics.log("source: seek to byte \(offset)")
            completion()
        }
    }

    /// Must be called on `queue`.
    private func startRequest(rangeOffset: Int64) {
        guard self.failure == nil, !self.stopped else { return }
        self.rangeOffset = rangeOffset
        var request = URLRequest(url: httpURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if rangeOffset > 0 {
            request.setValue("bytes=\(rangeOffset)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        dataTask = task
        task.resume()
    }

    /// Backpressure: stop reading from the socket. The TCP receive window fills
    /// and the server stops sending. Without this a recording (served as fast as
    /// the connection allows, unlike a rate-limited live stream) floods the
    /// decoder and the decoded-frame queues grow until the app is OOM-killed.
    func pause() {
        queue.async {
            guard !self.stopped, !self.paused, let task = self.dataTask else { return }
            self.paused = true
            task.suspend()
        }
    }

    /// Resume once the consumer has drained its buffer back down.
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
            self.onData = nil
            self.onFinish = nil
            self.onError = nil
            self.onReset = nil
            self.dataTask?.cancel()
            self.dataTask = nil
            // URLSession holds a strong reference to its delegate until it is
            // invalidated, so cancel it on the queue before any completion
            // callback can deliver buffered data after stop().
            self.session.invalidateAndCancel()
        }
    }

    private func fail(_ error: TStreamError) {
        guard failure == nil, !stopped else { return }
        failure = error
        onError?(error)
    }
}

extension HTTPByteStream: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            // Drop bytes from a task we've already replaced (e.g. after a seek).
            guard self.failure == nil, !self.stopped, dataTask == self.dataTask else { return }
            self.onData?(data)
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
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        queue.async { [weak self] in
            guard let self else { return }
            if expected > 0 { self.setLength(self.rangeOffset + expected) }
            if let mime { self.contentType = mime }
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
            self.onFinish?()
        }
    }
}
