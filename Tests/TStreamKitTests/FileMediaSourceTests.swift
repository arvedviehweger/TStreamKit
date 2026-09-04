import XCTest
@testable import TStreamKit

/// A downloaded recording has to reach the decoder the same way a streamed one
/// does — same detection, same demuxers — and be seekable, since the whole file
/// is already on disk.
final class FileMediaSourceTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-source-\(UUID().uuidString).ts")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func writeTransportStream(extraPackets: Int = 0) {
        let videoPID: UInt16 = 0x0100
        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true,
                            payload: TS.pmt(videoPID: videoPID, audio: [(0x0F, 0x0101, [])]))
        stream += TS.packet(pid: videoPID, payloadUnitStart: true, continuityCounter: 0,
                            payload: TS.pes(streamID: 0xE0, pts: 9000,
                                            payload: [0x00, 0x00, 0x01, 0x65]))
        stream += TS.packet(pid: videoPID, payloadUnitStart: true, continuityCounter: 1,
                            payload: TS.pes(streamID: 0xE0, pts: 12600,
                                            payload: [0x00, 0x00, 0x01, 0x41]))
        for i in 0..<extraPackets {
            stream += TS.packet(pid: videoPID, payloadUnitStart: true,
                                continuityCounter: UInt8((i + 2) & 0x0F),
                                payload: TS.pes(streamID: 0xE0, pts: UInt64(16_200 + i * 3600),
                                                payload: [0x00, 0x00, 0x01, 0x41]))
        }
        try! Data(stream).write(to: fileURL)
    }

    func testDetectsTransportStreamAndProducesVideo() {
        writeTransportStream()

        let spy = MediaSourceSpy()
        let source = FileMediaSource(url: fileURL)
        source.delegate = spy
        source.start()

        wait(for: [spy.received], timeout: 5)
        source.stop()

        XCTAssertEqual(spy.errors, [])
        XCTAssertEqual(spy.video.first?.codec, .h264)
        XCTAssertEqual(spy.video.first?.pts, 9000)
    }

    /// A file that isn't there has to say so, not sit on a black screen.
    func testMissingFileReportsAnError() {
        let spy = MediaSourceSpy()
        let source = FileMediaSource(url: fileURL)   // never written
        source.delegate = spy
        source.start()

        wait(for: [spy.received], timeout: 5)
        source.stop()

        XCTAssertTrue(spy.video.isEmpty)
        guard case .transport? = spy.errors.first else {
            return XCTFail("expected a transport error, got \(spy.errors)")
        }
    }

    /// Scrubbing a downloaded recording is the point of having it locally, so
    /// the source has to report itself seekable once the container is known.
    func testBecomesSeekableOnceTheContainerIsIdentified() {
        writeTransportStream(extraPackets: 40)

        let spy = MediaSourceSpy()
        let source = FileMediaSource(url: fileURL)
        source.delegate = spy
        XCTAssertFalse(source.isSeekable, "nothing has been read yet")
        source.start()

        wait(for: [spy.received], timeout: 5)
        XCTAssertTrue(source.isSeekable)

        let seeked = expectation(description: "seek completed")
        source.seek(toFraction: 0.5) { seeked.fulfill() }
        wait(for: [seeked], timeout: 5)
        source.stop()

        XCTAssertEqual(spy.errors, [])
    }
}
