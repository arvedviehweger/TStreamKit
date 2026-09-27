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
