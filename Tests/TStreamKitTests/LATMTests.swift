import XCTest
@testable import TStreamKit

final class LATMTests: XCTestCase {
    func testParsesAACLCConfigAndPayload() {
        let payload: [UInt8] = [0x21, 0x10, 0x05, 0x00, 0xCD, 0xEF]
        let parser = LATMParser()

        let frames = parser.parse(TS.loasAAC(payload: payload, sampleRateIndex: 3, channels: 2))

        XCTAssertEqual(frames, [payload])
        XCTAssertEqual(parser.config?.sampleRate, 48000)   // sampleRateIndex 3
        XCTAssertEqual(parser.config?.channels, 2)
        // 2-byte AAC-LC ASC: AOT=2, srIndex=3, channels=2 → 0x11 0x90.
        XCTAssertEqual(parser.config.map { [UInt8]($0.audioSpecificConfig) }, [0x11, 0x90])
    }

    func testReusesCachedConfigOnSameStreamMux() {
        let parser = LATMParser()
        _ = parser.parse(TS.loasAAC(payload: [0xAA, 0xBB], sampleRateIndex: 4, channels: 2))
        XCTAssertEqual(parser.config?.sampleRate, 44100)   // sampleRateIndex 4

        // A frame that omits the StreamMuxConfig must still decode via the cache.
        let second: [UInt8] = [0x01, 0x02, 0x03]
        let frames = parser.parse(TS.loasAAC(payload: second, sameStreamMux: true))
        XCTAssertEqual(frames, [second])
        XCTAssertEqual(parser.config?.sampleRate, 44100)
    }

    func testFramesBeforeConfigSeenAreDropped() {
        // A stream joined mid-config (useSameStreamMux with no cached config yet)
        // yields nothing rather than garbage.
        let parser = LATMParser()
        let frames = parser.parse(TS.loasAAC(payload: [0x11, 0x22], sameStreamMux: true))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertNil(parser.config)
    }

    func testLongPayloadUsesMultiByteLengthInfo() {
        // > 255 bytes exercises the PayloadLengthInfo 255-escape accumulation.
        let payload = (0..<300).map { UInt8($0 & 0xFF) }
        let parser = LATMParser()
        let frames = parser.parse(TS.loasAAC(payload: payload))
        XCTAssertEqual(frames, [payload])
    }

    func testDemuxerRoutesLATMStreamTypeAsAAC() {
        // DVB AAC-LATM is PMT stream_type 0x11; the demuxer must surface it as
        // AAC (codec .aac) with raw access units, like ADTS.
        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy

        let parser = TSPacketParser()
        let videoPID: UInt16 = 0x0100
        let audioPID: UInt16 = 0x0101
        let payload: [UInt8] = [0x21, 0x33, 0x44]

        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true, payload: TS.pmt(
            videoPID: videoPID, audio: [(0x11, audioPID, [])]))
        stream += TS.packet(pid: audioPID, payloadUnitStart: true,
                            payload: TS.pes(streamID: 0xC0, pts: 9000,
                                            payload: TS.loasAAC(payload: payload, sampleRateIndex: 3, channels: 2)))

        for packet in parser.push(Data(stream)) { demuxer.consume(packet) }
        demuxer.flush()

        XCTAssertTrue(spy.hasAudio)
        XCTAssertEqual(spy.audioFormat?.codec, .aac)
        XCTAssertEqual(spy.audioFormat?.sampleRate, 48000)
        XCTAssertEqual(spy.audioUnits.count, 1)
        XCTAssertEqual(spy.audioUnits.first.map { [UInt8]($0.data) }, payload)
        XCTAssertEqual(spy.audioUnits.first?.pts, 9000)
    }
}
