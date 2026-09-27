import Foundation

/// A disk-backed ring of *compressed* access units, so live TV can be paused
/// and rewound.
///
/// Keeping the buffer on disk rather than in memory is the whole point. The
/// player already holds several seconds of *decoded* frames — an uncompressed
/// HD frame is ~3 MB — so a RAM ring big enough to be useful would double the
/// app's footprint and get it jetsammed. Compressed units are ~30× smaller and
/// the page cache absorbs the I/O.
///
/// Payloads are appended to fixed-size chunk files; an in-memory index records
/// where each unit lives plus its timestamps. Trimming deletes whole chunks,
/// which is what keeps reclaiming space to a single `unlink` rather than a
/// rewrite of the ring.
///
/// Not thread-safe. Every method must be called on the owning source's queue,
/// with the sole exception of `span`, which takes a lock so the player can read
/// it from its render queue.
final class TimeshiftBuffer {

    struct Entry {
        let isVideo: Bool
        let chunk: Int
        let offset: Int
        let length: Int
        let pts: UInt64
        let dts: UInt64
        /// Only meaningful for video: a point a fresh decoder can start from.
        let isKeyframe: Bool
    }

    struct Configuration: Sendable {
        /// How far back the buffer lets the viewer rewind.
        var maximumDuration: TimeInterval
        /// Hard ceiling on disk use, whichever limit is hit first.
        var maximumBytes: Int
        /// Where the chunk files live. Defaults to the caches directory, which
        /// the system may purge when it needs space — acceptable for a buffer
        /// that is worthless the moment playback ends.
        var directory: URL?
        /// Bytes per chunk file. 16 MB is 20–60 seconds at broadcast bitrates,
        /// which is the granularity the oldest end of the ring is reclaimed in.
        var chunkBytes: Int

        init(maximumDuration: TimeInterval = 3600,
             maximumBytes: Int = 1_500_000_000,
             directory: URL? = nil,
             chunkBytes: Int = 16 * 1024 * 1024) {
            self.maximumDuration = maximumDuration
            self.maximumBytes = maximumBytes
            self.directory = directory
            self.chunkBytes = max(1, chunkBytes)
        }
    }

    /// A backwards timestamp jump larger than this means the stream restarted
    /// (or the 33-bit MPEG-TS clock wrapped). Everything buffered before it is
    /// unreachable from the new timeline, so the ring starts over.
    private static let discontinuityTicks: UInt64 = 10 * 90_000

    private let configuration: Configuration
    private let directory: URL
    private let fileManager = FileManager.default

    /// Whether any video has ever been buffered. An audio-only stream restarts
    /// on audio instead; a stream with video must not, since audio between two
    /// keyframes is no place to start decoding.
    private var sawVideo = false
    /// Index entries, oldest first. `baseIndex` is the global index of
    /// `entries[0]`, so indices handed out stay valid (as "gone") after a trim.
    private var entries: [Entry] = []
    private var baseIndex = 0

    private var writeHandle: FileHandle?
    private var writeChunk = 0
    private var writeOffset = 0
    private var readHandle: FileHandle?
    private var readChunk = -1
    /// Chunk index of the oldest chunk still on disk.
    private var oldestChunk = 0
    private var totalBytes = 0

    private let spanLock = NSLock()
    private var _span: (earliest: UInt64, latest: UInt64)?

    /// Oldest and newest timestamp held, in 90 kHz ticks. Safe to read from any
    /// thread.
    var span: (earliest: UInt64, latest: UInt64)? {
        spanLock.lock(); defer { spanLock.unlock() }
        return _span
    }

    /// Global index of the oldest entry still on disk.
    var startIndex: Int { baseIndex }
    /// One past the newest entry.
    var endIndex: Int { baseIndex + entries.count }

    init?(configuration: Configuration) {
        self.configuration = configuration
        let root = configuration.directory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let root else { return nil }
        let dir = root.appendingPathComponent("TStreamTimeshift/\(UUID().uuidString)",
                                              isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            TStreamDiagnostics.log("timeshift: could not create the buffer directory — \(error)")
            return nil
        }
        self.directory = dir
        guard openWriteChunk(0) else {
            try? fileManager.removeItem(at: dir)
            return nil
        }
    }

    deinit {
        try? writeHandle?.close()
        try? readHandle?.close()
        try? fileManager.removeItem(at: directory)
    }

    /// Discards everything and deletes the files. The buffer is unusable
    /// afterwards; the owner drops its reference.
    func tearDown() {
        try? writeHandle?.close(); writeHandle = nil
        try? readHandle?.close(); readHandle = nil
        entries.removeAll()
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Writing

    /// Appends one access unit. Returns false on an I/O failure, which the
    /// caller treats as "timeshift is over" — live playback carries on.
    @discardableResult
    func append(isVideo: Bool, data: Data, pts: UInt64, dts: UInt64, isKeyframe: Bool) -> Bool {
        guard !data.isEmpty else { return true }

        if let latest = _spanUnsafeLatest, pts &+ Self.discontinuityTicks < latest {
            TStreamDiagnostics.log("timeshift: timeline discontinuity, resetting the buffer")
            reset()
        }

        if writeOffset >= configuration.chunkBytes {
            guard openWriteChunk(writeChunk + 1) else { return false }
        }
        guard let handle = writeHandle else { return false }
        do {
            try handle.write(contentsOf: data)
        } catch {
            TStreamDiagnostics.log("timeshift: write failed — \(error)")
            return false
        }

        if isVideo { sawVideo = true }
        entries.append(Entry(isVideo: isVideo, chunk: writeChunk, offset: writeOffset,
                             length: data.count, pts: pts, dts: dts, isKeyframe: isKeyframe))
        writeOffset += data.count
        totalBytes += data.count
        updateSpan()
        trim()
        return true
    }

    // MARK: - Reading

    func entry(at index: Int) -> Entry? {
        let local = index - baseIndex
        guard local >= 0, local < entries.count else { return nil }
        return entries[local]
    }

    /// Payload bytes for an entry. Nil once the entry's chunk has been trimmed
    /// away or if the read fails.
    func payload(for entry: Entry) -> Data? {
        guard entry.chunk >= oldestChunk else { return nil }
        guard let handle = handleForReading(chunk: entry.chunk) else { return nil }
        do {
            try handle.seek(toOffset: UInt64(entry.offset))
            let data = try handle.read(upToCount: entry.length)
            // A short read means the chunk was trimmed under us; treat it as a
            // miss rather than handing the decoder a truncated access unit.
            guard let data, data.count == entry.length else { return nil }
            return data
        } catch {
            TStreamDiagnostics.log("timeshift: read failed — \(error)")
            return nil
        }
    }

    /// Index of the newest video keyframe at or before `pts`, which is where a
    /// rewind has to restart. Falls back to the oldest keyframe when the target
    /// is older than anything buffered, so seeking past the start clamps
    /// instead of failing.
    ///
    /// A radio channel has no video to restart on, and every audio unit is a
    /// random-access point, so there any entry will do — otherwise rewinding it
    /// would find nothing and silently do nothing.
    func indexOfSyncPoint(atOrBefore pts: UInt64) -> Int? {
        var candidate: Int?
        for (offset, entry) in entries.enumerated() {
            guard entry.isKeyframe, entry.isVideo || !sawVideo else { continue }
            if entry.pts <= pts {
                candidate = baseIndex + offset
            } else if candidate != nil {
                break
            } else {
                // Everything buffered starts after the target — clamp to the
                // first available restart point.
                return baseIndex + offset
            }
        }
        return candidate
    }

    // MARK: - Chunk plumbing

    private func chunkURL(_ index: Int) -> URL {
        directory.appendingPathComponent(String(format: "chunk-%06d.bin", index))
    }

    private func openWriteChunk(_ index: Int) -> Bool {
        try? writeHandle?.close()
        writeHandle = nil
        let url = chunkURL(index)
        guard fileManager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            TStreamDiagnostics.log("timeshift: could not open chunk \(index) for writing")
            return false
        }
        writeHandle = handle
        writeChunk = index
        writeOffset = 0
        return true
    }

    /// Replay walks the ring in order, so one cached read handle covers it.
    private func handleForReading(chunk: Int) -> FileHandle? {
        if chunk == readChunk, let readHandle { return readHandle }
        try? readHandle?.close()
        readHandle = try? FileHandle(forReadingFrom: chunkURL(chunk))
        readChunk = readHandle == nil ? -1 : chunk
        return readHandle
    }

    // MARK: - Trimming

    private func trim() {
        while shouldTrim, oldestChunk < writeChunk {
            let dropped = oldestChunk
            if readChunk == dropped {
                try? readHandle?.close()
                readHandle = nil
                readChunk = -1
            }
            try? fileManager.removeItem(at: chunkURL(dropped))
            oldestChunk += 1

            var removed = 0
            var bytes = 0
            for entry in entries {
                guard entry.chunk == dropped else { break }
                removed += 1
                bytes += entry.length
            }
            guard removed > 0 else { continue }
            entries.removeFirst(removed)
            baseIndex += removed
            totalBytes -= bytes
        }
        updateSpan()
    }

    private var shouldTrim: Bool {
        if totalBytes > configuration.maximumBytes { return true }
        guard let first = entries.first, let last = entries.last else { return false }
        let seconds = Double(last.pts &- first.pts) / 90_000
        return seconds > configuration.maximumDuration
    }

    private func reset() {
        try? writeHandle?.close(); writeHandle = nil
        try? readHandle?.close(); readHandle = nil
        readChunk = -1
        if oldestChunk <= writeChunk {
            for index in oldestChunk...writeChunk {
                try? fileManager.removeItem(at: chunkURL(index))
            }
        }
        // Indices are never reused, so a consumer holding a stale one sees it
        // fall outside `startIndex..<endIndex` and re-syncs instead of reading
        // somebody else's bytes.
        baseIndex += entries.count
        entries.removeAll(keepingCapacity: true)
        totalBytes = 0
        oldestChunk = writeChunk + 1
        _ = openWriteChunk(writeChunk + 1)
        updateSpan()
    }

    private var _spanUnsafeLatest: UInt64? { entries.last?.pts }

    private func updateSpan() {
        let value: (UInt64, UInt64)?
        if let first = entries.first, let last = entries.last {
            value = (first.pts, last.pts)
        } else {
            value = nil
        }
        spanLock.lock()
        _span = value
        spanLock.unlock()
    }
}
