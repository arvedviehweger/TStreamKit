import XCTest
@testable import TStreamKit

final class TSPacketParserTests: XCTestCase {
    func testParsesTwoAlignedPackets() {
        let parser = TSPacketParser()
        var bytes = TS.packet(pid: 0x0100, payloadUnitStart: true, payload: [0x01, 0x02, 0x03])
        bytes += TS.packet(pid: 0x0101, payloadUnitStart: false, payload: [0x04, 0x05])

        let packets = parser.push(Data(bytes))
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].pid, 0x0100)
        XCTAssertTrue(packets[0].payloadUnitStart)
        XCTAssertEqual(packets[0].payload.first, 0x01)
        XCTAssertEqual(packets[1].pid, 0x0101)
        XCTAssertFalse(packets[1].payloadUnitStart)
    }

    func testBuffersPartialPacketAcrossPushes() {
        let parser = TSPacketParser()
        let full = TS.packet(pid: 0x0100, payloadUnitStart: true, payload: [0xAA])
        XCTAssertTrue(parser.push(Data(full[0..<100])).isEmpty)
        let packets = parser.push(Data(full[100...]))
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].pid, 0x0100)
    }

    func testResyncSkipsLeadingGarbage() {
        let parser = TSPacketParser()
        var bytes: [UInt8] = [0x11, 0x22, 0x33] // garbage, no sync byte
        bytes += TS.packet(pid: 0x0042, payloadUnitStart: true, payload: [0x09])

        let packets = parser.push(Data(bytes))
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].pid, 0x0042)
    }

    func testTransportErrorPacketIsDropped() {
        let parser = TSPacketParser()
        var packet = TS.packet(pid: 0x0100, payloadUnitStart: true, payload: [0x01])
        packet[1] |= 0x80 // transport_error_indicator
        let packets = parser.push(Data(packet))
        XCTAssertTrue(packets.isEmpty)
    }
}
