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
    /// Requests issued for this stream, counting retries and seeks. Only for
    /// the log, where an attempt that reports nothing is indistinguishable from
    /// one that was never made.
    private var attempt = 0
    /// Whether the one automatic retry has been spent. Not reset by a seek: a
    /// server that answers and sends nothing twice is not going to start.
    private var retriedEmptyResponse = false
    /// How long to wait before that retry. Long enough for a server to finish
    /// releasing the previous subscription, short enough not to feel like a
    /// hang.
    private static let emptyResponseRetryDelay = 0.75
    /// Body bytes delivered for the current request. Zero at the moment the
    /// connection drops says the server accepted the request and then sent
    /// nothing, which is a different problem from a stream that broke off.
    private var receivedBytes = 0
    /// Byte offset of the current request (0 for the initial, non-ranged fetch).
    private var rangeOffset: Int64 = 0

    /// A recording whose connection broke off is picked up again where it
    /// stopped, with a `Range` request, instead of ending playback. The usual
    /// cause is our own backpressure: a suspended task still runs its request
    /// timeout, so a pause longer than `stallTimeout` — the viewer pausing, or
    /// the decode buffer taking a while to drain at a low bitrate — ends in
    /// "The request timed out". Set while such a reconnect waits for `resume()`.
    private var reconnectOffset: Int64?
    /// Whether the current request continues an earlier one rather than
    /// starting the stream or a seek. Its bytes are appended without a reset,
    /// so a server that ignores `Range` must not be believed.
    private var isContinuation = false
    /// Reconnects in a row that brought no data. Reset by the first byte.
    private var reconnectsWithoutData = 0
    private static let maxReconnectsWithoutData = 3

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
            TStreamDiagnostics.log("source: started fetching \(self.httpURL.absoluteString)")
            self.startRequest(rangeOffset: 0)
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
            self.reconnectOffset = nil
            self.isContinuation = false
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
        self.receivedBytes = 0
        self.isContinuation = false
        var request = URLRequest(url: httpURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if rangeOffset > 0 {
            request.setValue("bytes=\(rangeOffset)-", forHTTPHeaderField: "Range")
        }
        attempt += 1
        TStreamDiagnostics.log(
            "source: request \(attempt)\(rangeOffset > 0 ? " from byte \(rangeOffset)" : "")")
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
            guard !self.stopped, self.paused else { return }
            self.paused = false
            if let offset = self.reconnectOffset {
                self.reconnectOffset = nil
                self.reconnect(at: offset)
            } else {
                self.dataTask?.resume()
            }
        }
    }

    /// On `queue`. Continues the stream at `offset` without an `onReset`: the
    /// consumer gets the next byte after the last one it saw.
    private func reconnect(at offset: Int64) {
        TStreamDiagnostics.log("source: reconnecting at byte \(offset)")
        startRequest(rangeOffset: offset)
        isContinuation = true
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
            if self.receivedBytes == 0 {
                TStreamDiagnostics.log("source: first \(data.count) bytes arrived")
            }
            self.reconnectsWithoutData = 0
            self.receivedBytes += data.count
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
        // A continuation answered from the start of the file would splice the
        // beginning of the recording into the middle of it.
        if let http = response as? HTTPURLResponse, http.statusCode != 206 {
            let continuing = queue.sync { isContinuation }
            if continuing {
                queue.async { [weak self] in
                    self?.fail(.transport("the server can't resume a recording mid-file"))
                }
                completionHandler(.cancel)
                return
            }
        }
        // expectedContentLength is the length of *this* response: for a ranged
        // request that's the remainder, so add the offset to get the total.
        let expected = response.expectedContentLength
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        queue.async { [weak self] in
            guard let self else { return }
            if expected > 0 { self.setLength(self.rangeOffset + expected) }
            if let mime { self.contentType = mime }
            TStreamDiagnostics.log(
                "source: HTTP \(status), content type \(mime ?? "none"), "
                + "length \(expected > 0 ? String(expected) : "unknown")")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            // Ignore completion of a task we've already replaced (seek/cancel).
            guard !self.stopped, task == self.dataTask else { return }
            if let error, (error as NSError).code != NSURLErrorCancelled {
                TStreamDiagnostics.log(
                    "source: request \(self.attempt) ended after \(self.receivedBytes) bytes")
                // A recording that was already playing: carry on from the
                // byte after the last one delivered. Only a finite resource
                // can be resumed like that; a live stream has no offsets.
                let position = self.rangeOffset + Int64(self.receivedBytes)
                let total = self.length
                if total > 0, position > 0, position < total,
                   self.reconnectsWithoutData < Self.maxReconnectsWithoutData {
                    self.reconnectsWithoutData += 1
                    self.dataTask = nil
                    TStreamDiagnostics.log(
                        "source: connection lost at byte \(position) — \(error.localizedDescription)")
                    if self.paused {
                        self.reconnectOffset = position
                    } else {
                        self.reconnect(at: position)
                    }
                    return
                }
                // The server answered and then dropped the connection without
                // ever sending a byte of media. That is not a network fault to
                // retry blindly: the request was accepted and the stream behind
                // it failed to start — a tuner already in use, a service that
                // cannot be subscribed, or a profile that cannot carry this
                // channel. Say so, because "the network connection was lost"
                // sends everyone looking in the wrong place.
                if self.receivedBytes == 0 {
                    TStreamDiagnostics.log(
                        "source: the server sent no data before closing — \(error.localizedDescription)")
                    // Tuning takes a moment to become possible again: a server
                    // still releasing the previous subscription answers and then
                    // drops the connection, and the same request a moment later
                    // succeeds. Worth exactly one retry — after that the refusal
                    // is real and the caller should hear about it.
                    if !self.retriedEmptyResponse {
                        self.retriedEmptyResponse = true
                        self.dataTask = nil
                        let offset = self.rangeOffset
                        TStreamDiagnostics.log("source: retrying once")
                        self.queue.asyncAfter(deadline: .now() + Self.emptyResponseRetryDelay) {
                            [weak self] in self?.startRequest(rangeOffset: offset)
                        }
                        return
                    }
                    self.fail(.transport("the server accepted the request but sent no stream"))
                    return
                }
                self.fail(.transport(error.localizedDescription))
                return
            }
            self.onFinish?()
        }
    }
}
