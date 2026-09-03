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
    /// Credentials for an HTTP auth challenge. A pre-set `Authorization` header
    /// only covers Basic; a server that asks for Digest has to be answered, and
    /// answering needs the password rather than a header derived from it.
    private let credential: URLCredential?
    private let queue: DispatchQueue
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    private let configuration: URLSessionConfiguration
    private var dataTask: URLSessionDataTask?
    private var failure: TStreamError?
    private var stopped = false
    private var paused = false

    /// How long a request may deliver nothing before it is given up on. Long
    /// enough for a tuner to lock and a transcoder to start.
    private static let stallTimeout: TimeInterval = 20
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
         credential: URLCredential? = nil,
         queue: DispatchQueue,
         configuration: URLSessionConfiguration = .default) {
        self.httpURL = url
        self.httpHeaders = headers
        self.credential = credential
        self.queue = queue
        // A live stream that goes quiet is dead, and the default minute of
        // patience is a minute of spinner before anything can react. This is the
        // gap between packets, not the length of the stream: continuous delivery
        // never trips it, and `timeoutIntervalForResource` — which does cap the
        // whole stream, and must stay at its default of days — is untouched.
        let timed = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        timed.timeoutIntervalForRequest = Self.stallTimeout
        self.configuration = timed
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
    /// Answers Basic and Digest challenges with the credentials the caller gave
    /// us. Without this a Digest-only server refuses the request and hangs up:
    /// it sends `401` with `Connection: Close` and closes before the response is
    /// read, which surfaces as a lost connection rather than as an auth failure.
    ///
    /// Only the first attempt is answered. Retrying wrong credentials loops, and
    /// letting the 401 through instead turns a hang into a clear "HTTP 401".
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodDefault:
            guard let credential, challenge.previousFailureCount == 0 else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            TStreamDiagnostics.log(
                "source: answering an auth challenge (\(challenge.protectionSpace.authenticationMethod))")
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

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
