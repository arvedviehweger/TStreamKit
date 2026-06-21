import Foundation

/// Pulls the HTTP MPEG-TS stream and runs it through the
/// parser → demuxer → muxer pipeline on a serial queue, filling an `HLSStore`
/// with the fMP4 init segment and media segments. The store is then served to
/// AVPlayer by `HLSLocalServer`.
final class TStreamPipeline: NSObject {
    let store: HLSStore

    /// Surfaces pipeline failures (called on the pipeline queue).
    var onError: ((TStreamError) -> Void)?
    /// Fired once when enough is buffered to start playback (pipeline queue).
    var onReady: (() -> Void)?

    private let httpURL: URL
    private let configuration: URLSessionConfiguration
    private let queue = DispatchQueue(label: "com.tstream.pipeline")
    private let minimumSegmentsToStart: Int

    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var dataTask: URLSessionDataTask?

    private let parser = TSPacketParser()
    private let demuxer = TSDemuxer()

    private var muxer: FMP4Muxer?
    private var videoFormat: VideoFormat?
    private var audioFormat: AudioFormat?
    private var expectsAudio = false
    private var streamsIdentified = false
    private var pendingVideo: [AccessUnit] = []
    private var pendingAudio: [AccessUnit] = []
    private var failure: TStreamError?
    private var didSignalReady = false

    // Diagnostics counters.
    private var bytesReceived = 0
    private var lastLoggedBytes = 0
    private var packetsParsed = 0
    private var videoUnitCount = 0
    private var audioUnitCount = 0

    init(httpURL: URL, minimumSegmentsToStart: Int = 3, configuration: URLSessionConfiguration = .default) {
        self.httpURL = httpURL
        self.minimumSegmentsToStart = minimumSegmentsToStart
        self.store = HLSStore()
        self.configuration = configuration
        super.init()
        demuxer.delegate = self
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.dataTask == nil, self.failure == nil else { return }
            var request = URLRequest(url: self.httpURL)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let task = self.session.dataTask(with: request)
            self.dataTask = task
            task.resume()
            TStreamDiagnostics.log("pipeline: started fetching \(self.httpURL.absoluteString)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.dataTask?.cancel()
            self?.dataTask = nil
        }
    }

    // MARK: - Muxer lifecycle

    private func buildMuxerIfReady() {
        guard muxer == nil, let videoFormat else { return }
        guard audioFormat != nil || (streamsIdentified && !expectsAudio) else { return }

        let muxer = FMP4Muxer(video: videoFormat, audio: audioFormat)
        muxer.onSegment = { [weak self] data, duration in
            guard let self else { return }
            let sequence = self.store.addSegment(data, duration: duration)
            TStreamDiagnostics.log("muxer: segment \(sequence) (\(data.count) bytes, \(String(format: "%.2f", duration))s)")
            self.signalReadyIfNeeded()
        }
        self.muxer = muxer

        let initSegment = muxer.initializationSegment()
        store.setInitSegment(initSegment)
        store.setVariant(codecs: codecsString(video: videoFormat, audio: audioFormat),
                         resolution: "\(videoFormat.width)x\(videoFormat.height)")
        TStreamDiagnostics.log("muxer: built init \(initSegment.count) bytes (\(videoFormat.width)x\(videoFormat.height), audio \(audioFormat != nil))")

        for unit in pendingVideo { muxer.addVideo(unit) }
        for unit in pendingAudio { muxer.addAudio(unit) }
        pendingVideo.removeAll()
        pendingAudio.removeAll()
    }

    private func signalReadyIfNeeded() {
        guard !didSignalReady, store.isReady(minimumSegments: minimumSegmentsToStart) else { return }
        didSignalReady = true
        TStreamDiagnostics.log("pipeline: ready (\(store.segmentCount) segments)")
        onReady?()
    }

    private func codecsString(video: VideoFormat, audio: AudioFormat?) -> String {
        var codecs = [video.codecParameters]
        switch audio?.codec {
        case .aac: codecs.append("mp4a.40.2") // AAC-LC
        case .ac3: codecs.append("ac-3")
        case .none: break
        }
        return codecs.joined(separator: ",")
    }

    private func fail(_ error: TStreamError) {
        guard failure == nil else { return }
        failure = error
        onError?(error)
    }
}

// MARK: - URLSessionDataDelegate

extension TStreamPipeline: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            guard let self, self.failure == nil else { return }
            self.bytesReceived += data.count
            let packets = self.parser.push(data)
            self.packetsParsed += packets.count
            for packet in packets { self.demuxer.consume(packet) }
            if self.bytesReceived - self.lastLoggedBytes > 200_000 {
                self.lastLoggedBytes = self.bytesReceived
                TStreamDiagnostics.log("net: \(self.bytesReceived) bytes, \(self.packetsParsed) packets, video AUs \(self.videoUnitCount), audio AUs \(self.audioUnitCount), segments \(self.store.segmentCount)")
            }
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
        queue.async { [weak self] in
            guard let self else { return }
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.fail(.transport(error.localizedDescription))
                return
            }
            self.demuxer.flush()
            self.muxer?.finish()
            self.signalReadyIfNeeded()
        }
    }
}

// MARK: - TSDemuxerDelegate

extension TStreamPipeline: TSDemuxerDelegate {
    func demuxer(_ demuxer: TSDemuxer, didIdentifyStreamsHasVideo hasVideo: Bool, hasAudio: Bool) {
        streamsIdentified = true
        expectsAudio = hasAudio
        TStreamDiagnostics.log("demux: PMT — video \(hasVideo), audio \(hasAudio)")
        if !hasVideo { fail(.demux("no supported video stream in PMT")); return }
        buildMuxerIfReady()
    }

    func demuxer(_ demuxer: TSDemuxer, didParseVideoFormat format: VideoFormat) {
        videoFormat = format
        TStreamDiagnostics.log("demux: video \(format.width)x\(format.height)")
        buildMuxerIfReady()
    }

    func demuxer(_ demuxer: TSDemuxer, didParseAudioFormat format: AudioFormat) {
        audioFormat = format
        TStreamDiagnostics.log("demux: audio \(format.sampleRate)Hz \(format.channels)ch")
        buildMuxerIfReady()
    }

    func demuxer(_ demuxer: TSDemuxer, didProduceVideo unit: AccessUnit) {
        videoUnitCount += 1
        if let muxer { muxer.addVideo(unit) } else { pendingVideo.append(unit) }
    }

    func demuxer(_ demuxer: TSDemuxer, didProduceAudio unit: AccessUnit) {
        audioUnitCount += 1
        if let muxer { muxer.addAudio(unit) } else { pendingAudio.append(unit) }
    }

    func demuxer(_ demuxer: TSDemuxer, didFail error: TStreamError) {
        switch error {
        case .unsupportedCodec: break // optional codec; keep playing video
        default: fail(error)
        }
    }
}
