import Foundation

/// Plays a recording that already lives on the device.
///
/// `URLSession` can't fetch `file:` URLs, so a downloaded recording needs its
/// own source rather than a different URL through `HTTPMediaSource`. Everything
/// past the read is identical — the same container pipeline, the same demuxers
/// — and a local file is fully seekable, so downloaded recordings scrub exactly
/// like streamed ones.
///
/// All delegate callbacks are delivered on the private `queue`.
final class FileMediaSource: MediaSource {
    weak var delegate: MediaSourceDelegate?
    var onError: ((TStreamError) -> Void)?

    private let queue = DispatchQueue(label: "com.tstream.file")
    private let url: URL
    private let pipeline = ContainerPipeline()

    private var handle: FileHandle?
    private var totalBytes: Int64 = 0
    private var paused = false
    private var reading = false
    private var stopped = false
    private var failed = false

    /// 256 KB per read: big enough that the syscall overhead disappears, small
    /// enough that a pause takes effect promptly.
    private static let chunkBytes = 256 * 1024

    init(url: URL) {
        self.url = url
        pipeline.output = self
        pipeline.onFail = { [weak self] error in self?.fail(error) }
    }

    func start() {
        queue.async {
            guard self.handle == nil, !self.stopped, !self.failed else { return }
            guard let handle = try? FileHandle(forReadingFrom: self.url) else {
                self.fail(.transport("could not open \(self.url.lastPathComponent)"))
                return
            }
            self.handle = handle
            let size = (try? FileManager.default.attributesOfItem(atPath: self.url.path)[.size]) as? NSNumber
            self.totalBytes = size?.int64Value ?? 0
            TStreamDiagnostics.log("file: playing \(self.url.lastPathComponent), \(self.totalBytes) bytes")
            self.scheduleRead()
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.delegate = nil
            self.onError = nil
            try? self.handle?.close()
            self.handle = nil
            self.pipeline.stop()
        }
    }

    /// Backpressure: a local file reads far faster than real time, so without
    /// this the decoded-frame queues would grow until the app is OOM-killed —
    /// the same reason the HTTP source suspends its task.
    func pause() {
        queue.async { self.paused = true }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            self.scheduleRead()
        }
    }

    /// A file always has a length; only an unrecognised container blocks a seek.
    var isSeekable: Bool { totalBytes > 0 && pipeline.isIdentified }

    func seek(toFraction fraction: Double, completion: @escaping () -> Void) {
        queue.async {
            defer { completion() }
            guard !self.stopped, let handle = self.handle, self.totalBytes > 0 else { return }
            let clamped = min(max(fraction, 0), 1)
            let offset = UInt64(Double(self.totalBytes) * clamped)
            // Landing mid-structure is expected: TS resyncs to the next packet
            // from anywhere and the libavformat path restarts its probe, with
            // decoding resuming at the next keyframe either way.
            try? handle.seek(toOffset: offset)
            self.pipeline.reset()
            self.paused = false
            self.scheduleRead()
        }
    }

    // MARK: - Reading

    /// On `queue`. Hops back through the queue between chunks so pause, seek
    /// and stop are all serviced between reads rather than after the file.
    private func scheduleRead() {
        guard !reading, !stopped, !failed, !paused, handle != nil else { return }
        reading = true
        queue.async { self.readChunk() }
    }

    private func readChunk() {
        reading = false
        guard !stopped, !failed, !paused, let handle else { return }

        let data: Data?
        do {
            data = try handle.read(upToCount: Self.chunkBytes)
        } catch {
            fail(.transport(error.localizedDescription))
            return
        }
        guard let data, !data.isEmpty else {
            pipeline.finish()
            return
        }
        pipeline.consume(data)
        scheduleRead()
    }

    /// On `queue`. Reports once and then goes quiet.
    private func fail(_ error: TStreamError) {
        guard !failed, !stopped else { return }
        failed = true
        TStreamDiagnostics.log("file: failed with \(error.localizedDescription)")
        onError?(error)
        delegate?.mediaSource(self, didFail: error)
    }
}

// Forward the demuxer's output to the player.
extension FileMediaSource: StreamDemuxerOutput {
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
