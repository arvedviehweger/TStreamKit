import XCTest
@testable import TStreamKit

// MARK: - Ring buffer

final class TimeshiftBufferTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeshift-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeBuffer(maximumDuration: TimeInterval = 3600,
                            maximumBytes: Int = 1_000_000,
                            chunkBytes: Int = 1024) -> TimeshiftBuffer {
        let config = TimeshiftBuffer.Configuration(maximumDuration: maximumDuration,
                                                   maximumBytes: maximumBytes,
                                                   directory: directory,
                                                   chunkBytes: chunkBytes)
        return XCTUnwrap_(TimeshiftBuffer(configuration: config))
    }

    private func XCTUnwrap_<T>(_ value: T?) -> T {
        guard let value else {
            XCTFail("could not create the buffer")
            fatalError("unreachable")
        }
        return value
    }

    /// The point of the ring: what goes in comes back out byte for byte, in
    /// order, across chunk boundaries.
    func testRoundTripsPayloadsAcrossChunks() {
        let buffer = makeBuffer(chunkBytes: 64)
        var expected: [Data] = []
        for i in 0..<40 {
            let payload = Data(repeating: UInt8(i), count: 10)
            expected.append(payload)
            XCTAssertTrue(buffer.append(isVideo: i % 2 == 0, data: payload,
                                        pts: UInt64(i) * 3600, dts: UInt64(i) * 3600,
                                        isKeyframe: i % 10 == 0))
        }
        XCTAssertEqual(buffer.startIndex, 0)
        XCTAssertEqual(buffer.endIndex, 40)
        for i in 0..<40 {
            let entry = XCTUnwrap_(buffer.entry(at: i))
            XCTAssertEqual(buffer.payload(for: entry), expected[i], "unit \(i)")
        }
    }

    /// A rewind can only restart at a keyframe, so the lookup has to land on
    /// the newest one at or before the target rather than the nearest.
    func testFindsKeyframeAtOrBeforeTimestamp() {
        let buffer = makeBuffer()
        // Keyframes at 0 s, 2 s and 4 s; non-keyframes in between.
        for i in 0..<9 {
            buffer.append(isVideo: true, data: Data([UInt8(i)]),
                          pts: UInt64(i) * 90_000, dts: UInt64(i) * 90_000,
                          isKeyframe: i % 2 == 0)
        }
        XCTAssertEqual(buffer.indexOfSyncPoint(atOrBefore: 5 * 90_000), 4)   // 4 s keyframe
        XCTAssertEqual(buffer.indexOfSyncPoint(atOrBefore: 4 * 90_000), 4)
        XCTAssertEqual(buffer.indexOfSyncPoint(atOrBefore: 90_000), 0)       // 0 s keyframe
    }

    /// A radio channel buffers no video, so a rewind that insisted on a video
    /// keyframe would find nothing and silently do nothing. Every audio unit is
    /// a random-access point, so any of them will do.
    func testAudioOnlyStreamRestartsOnAudio() {
        let buffer = makeBuffer()
        for i in 0..<5 {
            buffer.append(isVideo: false, data: Data([UInt8(i)]),
                          pts: UInt64(i) * 90_000, dts: UInt64(i) * 90_000, isKeyframe: true)
        }
        XCTAssertEqual(buffer.indexOfSyncPoint(atOrBefore: 3 * 90_000), 3)
    }

    /// But once there is video, audio is no place to restart: decoding has to
    /// pick up at a keyframe, not somewhere in the middle of a GOP.
    func testAudioIsNotARestartPointWhenTheStreamHasVideo() {
        let buffer = makeBuffer()
        buffer.append(isVideo: true, data: Data([0]), pts: 0, dts: 0, isKeyframe: true)
        for i in 1..<5 {
            buffer.append(isVideo: false, data: Data([UInt8(i)]),
                          pts: UInt64(i) * 90_000, dts: UInt64(i) * 90_000, isKeyframe: true)
        }
        XCTAssertEqual(buffer.indexOfSyncPoint(atOrBefore: 3 * 90_000), 0)
    }

    /// Seeking further back than the buffer reaches clamps to the oldest
    /// restart point instead of failing — the viewer gets the earliest picture
    /// there is rather than nothing.
    func testSeekingBeforeTheBufferClampsToTheOldestKeyframe() {
        let buffer = makeBuffer()
        for i in 0..<4 {
            buffer.append(isVideo: true, data: Data([UInt8(i)]),
                          pts: 100 * 90_000 + UInt64(i) * 90_000,
                          dts: 100 * 90_000 + UInt64(i) * 90_000,
                          isKeyframe: i == 0)
        }
        XCTAssertEqual(buffer.indexOfSyncPoint(atOrBefore: 0), 0)
    }

    /// Over budget, whole chunks are dropped from the oldest end and the
    /// indices they held stop resolving — that is how the ring stays bounded.
    func testTrimsOldestChunksWhenOverTheByteBudget() {
        let buffer = makeBuffer(maximumBytes: 300, chunkBytes: 100)
        for i in 0..<40 {
            buffer.append(isVideo: true, data: Data(repeating: UInt8(i), count: 50),
                          pts: UInt64(i) * 3600, dts: UInt64(i) * 3600, isKeyframe: true)
        }
        XCTAssertGreaterThan(buffer.startIndex, 0, "nothing was reclaimed")
        XCTAssertEqual(buffer.endIndex, 40)
        XCTAssertNil(buffer.entry(at: 0), "a trimmed index must not resolve")
        let newest = XCTUnwrap_(buffer.entry(at: buffer.endIndex - 1))
        XCTAssertEqual(buffer.payload(for: newest), Data(repeating: 39, count: 50))
    }

    func testTrimsWhenOverTheDurationBudget() {
        let buffer = makeBuffer(maximumDuration: 10, chunkBytes: 8)
        for i in 0..<60 {
            buffer.append(isVideo: true, data: Data([UInt8(i)]),
                          pts: UInt64(i) * 90_000, dts: UInt64(i) * 90_000, isKeyframe: true)
        }
        let span = XCTUnwrap_(buffer.span)
        let seconds = Double(span.latest - span.earliest) / 90_000
        XCTAssertLessThanOrEqual(seconds, 10)
    }

    /// A stream restart (or the 33-bit MPEG-TS clock wrapping) makes everything
    /// buffered unreachable from the new timeline, so the ring starts over
    /// rather than serving units the player can never schedule.
    func testBackwardsDiscontinuityResetsTheBuffer() {
        let buffer = makeBuffer()
        for i in 0..<5 {
            buffer.append(isVideo: true, data: Data([UInt8(i)]),
                          pts: 1_000 * 90_000 + UInt64(i) * 90_000,
                          dts: 0, isKeyframe: true)
        }
        let indexBefore = buffer.endIndex
        buffer.append(isVideo: true, data: Data([99]), pts: 90_000, dts: 0, isKeyframe: true)

        XCTAssertEqual(buffer.startIndex, indexBefore, "stale indices must not resolve")
        XCTAssertNil(buffer.entry(at: 0))
        let span = XCTUnwrap_(buffer.span)
        XCTAssertEqual(span.earliest, 90_000)
        XCTAssertEqual(span.latest, 90_000)
    }
}

// MARK: - Source wrapper

/// A live source the test drives by hand.
private final class FakeLiveSource: MediaSource {
    weak var delegate: MediaSourceDelegate?
    var onError: ((TStreamError) -> Void)?

    private(set) var started = false
    private(set) var isPaused = false

    func start() { started = true }
    func stop() {}
    func pause() { isPaused = true }
    func resume() { isPaused = false }
    var isSeekable: Bool { false }
    func seek(toFraction fraction: Double, completion: @escaping () -> Void) { completion() }

    func pushVideo(pts: UInt64, keyframe: Bool, marker: UInt8) {
        delegate?.mediaSource(self, didProduceVideo: Data([marker]), codec: .h264,
                              pts: pts, dts: pts, isKeyframe: keyframe)
    }

    func pushAudio(pts: UInt64, marker: UInt8) {
        delegate?.mediaSource(self, didProduceAudio:
            AccessUnit(data: Data([marker]), pts: pts, dts: pts, isKeyframe: true))
    }
}

/// Records what reaches the player. Locked because the wrapper delivers on its
/// own queue while the test thread reads.
private final class TimeshiftSpy: MediaSourceDelegate {
    private let lock = NSLock()
    private var _video: [(pts: UInt64, marker: UInt8)] = []
    private var _audio: [(pts: UInt64, marker: UInt8)] = []

    var video: [(pts: UInt64, marker: UInt8)] {
        lock.lock(); defer { lock.unlock() }; return _video
    }
    var audio: [(pts: UInt64, marker: UInt8)] {
        lock.lock(); defer { lock.unlock() }; return _audio
    }
    var videoMarkers: [UInt8] { video.map(\.marker) }

    func mediaSource(_ source: MediaSource, didParseVideoFormat codec: VideoCodec,
                     extradata: Data?, pixelAspect: PixelAspect?) {}
    func mediaSource(_ source: MediaSource, didProduceVideo data: Data, codec: VideoCodec,
                     pts: UInt64, dts: UInt64, isKeyframe: Bool) {
        lock.lock(); _video.append((pts, data.first ?? 0)); lock.unlock()
    }
    func mediaSourceDidDetectAudioOnly(_ source: MediaSource) {}
    func mediaSource(_ source: MediaSource, didParseAudioFormat format: AudioFormat) {}
    func mediaSource(_ source: MediaSource, didProduceAudio unit: AccessUnit) {
        lock.lock(); _audio.append((unit.pts, unit.data.first ?? 0)); lock.unlock()
    }
    func mediaSource(_ source: MediaSource, didFail error: TStreamError) {}
}

final class TimeshiftMediaSourceTests: XCTestCase {
    private var directory: URL!
    private var inner: FakeLiveSource!
    private var spy: TimeshiftSpy!
    private var source: TimeshiftMediaSource!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeshift-src-\(UUID().uuidString)", isDirectory: true)
        inner = FakeLiveSource()
        spy = TimeshiftSpy()
        source = TimeshiftMediaSource(
            wrapping: inner,
            configuration: TimeshiftBuffer.Configuration(directory: directory, chunkBytes: 4096))
        source.delegate = spy
    }

    override func tearDown() {
        source.stop()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Spins the run loop until `condition` holds, so the wrapper's queue gets
    /// a chance to deliver.
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 3,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    func testBufferIsAvailableAndStartsLive() {
        XCTAssertTrue(source.isAvailable)
        XCTAssertTrue(source.isPlayingLive)
    }

    /// With nobody paused or rewound, the wrapper has to be invisible: every
    /// unit reaches the player as it arrives.
    func testLiveUnitsPassStraightThrough() {
        for i in 0..<5 {
            inner.pushVideo(pts: UInt64(i) * 3600, keyframe: i == 0, marker: UInt8(i))
            inner.pushAudio(pts: UInt64(i) * 3600, marker: UInt8(100 + i))
        }
        waitUntil("live pass-through") { self.spy.video.count == 5 && self.spy.audio.count == 5 }
        XCTAssertEqual(spy.videoMarkers, [0, 1, 2, 3, 4])
    }

    /// A pause must stop feeding the player *and* keep recording — otherwise
    /// resuming would skip whatever aired during the pause.
    func testHoldStopsForwardingButKeepsRecording() {
        inner.pushVideo(pts: 0, keyframe: true, marker: 0)
        waitUntil("first unit") { self.spy.video.count == 1 }

        source.beginHold()
        waitUntil("hold took effect") { !self.source.isPlayingLive }

        for i in 1...4 {
            inner.pushVideo(pts: UInt64(i) * 3600, keyframe: false, marker: UInt8(i))
        }
        // Give the queue time to prove it *doesn't* forward them.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(spy.videoMarkers, [0], "units aired during the pause must not be forwarded")
        XCTAssertFalse(inner.isPaused, "the download has to continue so the pause is recorded")
    }

    /// Resuming replays exactly what was missed, in order, and then rejoins the
    /// broadcast once it catches up.
    func testResumingReplaysWhatAiredDuringTheHold() {
        inner.pushVideo(pts: 0, keyframe: true, marker: 0)
        waitUntil("first unit") { self.spy.video.count == 1 }

        source.beginHold()
        waitUntil("hold took effect") { !self.source.isPlayingLive }
        for i in 1...4 {
            inner.pushVideo(pts: UInt64(i) * 3600, keyframe: false, marker: UInt8(i))
        }

        source.endHold()
        waitUntil("replay delivered") { self.spy.video.count == 5 }
        XCTAssertEqual(spy.videoMarkers, [0, 1, 2, 3, 4])
        waitUntil("caught back up with live") { self.source.isPlayingLive }
    }

    /// Rewinding restarts at the keyframe at or before the target, never in the
    /// middle of a GOP the decoder can't start on.
    func testSeekRestartsAtTheKeyframe() {
        // Keyframe at 0, then non-keyframes; a second keyframe at 0.4 s.
        inner.pushVideo(pts: 0, keyframe: true, marker: 0)
        inner.pushVideo(pts: 18_000, keyframe: false, marker: 1)
        inner.pushVideo(pts: 36_000, keyframe: true, marker: 2)
        inner.pushVideo(pts: 54_000, keyframe: false, marker: 3)
        waitUntil("live units") { self.spy.video.count == 4 }

        let seeked = expectation(description: "seek completed")
        source.seek(toTimestamp: 45_000) { seeked.fulfill() }
        wait(for: [seeked], timeout: 2)

        waitUntil("replay from the keyframe") { self.spy.video.count >= 6 }
        XCTAssertEqual(Array(spy.videoMarkers.prefix(6)), [0, 1, 2, 3, 2, 3])
    }

    /// Jumping back to live discards the backlog rather than fast-forwarding
    /// through it.
    func testReturnToLiveDropsTheBacklog() {
        inner.pushVideo(pts: 0, keyframe: true, marker: 0)
        waitUntil("first unit") { self.spy.video.count == 1 }

        source.beginHold()
        waitUntil("hold took effect") { !self.source.isPlayingLive }
        for i in 1...4 {
            inner.pushVideo(pts: UInt64(i) * 3600, keyframe: false, marker: UInt8(i))
        }

        let done = expectation(description: "returned to live")
        source.returnToLive { done.fulfill() }
        wait(for: [done], timeout: 2)
        waitUntil("live again") { self.source.isPlayingLive }

        inner.pushVideo(pts: 5 * 3600, keyframe: true, marker: 5)
        waitUntil("post-jump unit") { self.spy.video.count == 2 }
        XCTAssertEqual(spy.videoMarkers, [0, 5], "the backlog must not be replayed")
    }

    /// Backpressure while live still throttles the network, exactly as it did
    /// before timeshift existed.
    func testBackpressureWhileLiveThrottlesTheDownload() {
        source.pause()
        waitUntil("inner paused") { self.inner.isPaused }
        source.resume()
        waitUntil("inner resumed") { !self.inner.isPaused }
    }
}
