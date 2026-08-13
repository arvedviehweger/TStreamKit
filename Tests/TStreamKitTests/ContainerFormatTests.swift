import XCTest
@testable import TStreamKit

final class ContainerFormatTests: XCTestCase {

    // MARK: MPEG-TS

    func testDetectsTransportStreamFromSyncPattern() {
        let bytes = (0..<3).flatMap { _ in
            TS.packet(pid: 0x100, payloadUnitStart: true, payload: [0x01, 0x02])
        }
        XCTAssertEqual(ContainerFormat.detect(bytes), .mpegTS)
    }

    /// A live stream can be joined mid-packet, so detection has to scan forward
    /// rather than insist on a sync byte at offset zero.
    func testDetectsTransportStreamStartingMidPacket() {
        var bytes: [UInt8] = [0x11, 0x22, 0x33]
        bytes += (0..<3).flatMap { _ in
            TS.packet(pid: 0x100, payloadUnitStart: true, payload: [0xAA])
        }
        XCTAssertEqual(ContainerFormat.detect(bytes), .mpegTS)
    }

    /// One 0x47 with nothing at the 188-byte stride is not a transport stream.
    func testStraySyncByteIsNotTransportStream() {
        var bytes = [UInt8](repeating: 0x00, count: 1000)
        bytes[10] = 0x47
        XCTAssertNil(ContainerFormat.detect(bytes))
    }

    // MARK: Matroska / WebM

    func testDetectsMatroskaFromEBMLHeader() {
        let bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00]
        XCTAssertEqual(ContainerFormat.detect(bytes), .matroska)
    }

    /// WebM is Matroska, so the same header covers the vp8/vorbis profile.
    func testDetectsWebMAsMatroska() {
        var bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
        bytes += Array("webm".utf8)
        XCTAssertEqual(ContainerFormat.detect(bytes), .matroska)
    }

    // MARK: MP4

    func testDetectsMP4FromFtypBox() {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18]
        bytes += Array("ftypisom".utf8)
        XCTAssertEqual(ContainerFormat.detect(bytes), .mp4)
    }

    /// A fragmented segment leads with styp rather than ftyp.
    func testDetectsFragmentedMP4FromStypBox() {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18]
        bytes += Array("stypmsdh".utf8)
        XCTAssertEqual(ContainerFormat.detect(bytes), .mp4)
    }

    // MARK: Inconclusive input

    func testReturnsNilWhileTooFewBytes() {
        XCTAssertNil(ContainerFormat.detect([0x1A, 0x45]))
    }

    func testReturnsNilForUnknownBytes() {
        let bytes = [UInt8](repeating: 0x5A, count: 600)
        XCTAssertNil(ContainerFormat.detect(bytes))
    }
}
