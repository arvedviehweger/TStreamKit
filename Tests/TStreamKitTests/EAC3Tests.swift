import XCTest
@testable import TStreamKit

final class EAC3Tests: XCTestCase {
    func testFramingAndConfig() {
        // Two independent substreams → two separate access units.
        let frame = TS.eac3Frame(sizeBytes: 128, fscod: 0, numblkscod: 3, acmod: 2, lfeon: 0)
        let frames = EAC3.frames(in: frame + frame)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].raw.count, 128)

        let cfg = EAC3.config(from: frames[0].raw)
        XCTAssertEqual(cfg?.sampleRate, 48000)
        XCTAssertEqual(cfg?.channels, 2)
        XCTAssertEqual(cfg?.samplesPerFrame, 1536)   // numblkscod 3 → 6 blocks × 256
    }

    func testReducedSampleRateAndLFE() {
        // fscod == 3 selects a halved rate via fscod2 (0 → 24 kHz); 5.1 = acmod 7 + LFE.
        let frame = TS.eac3Frame(sizeBytes: 96, fscod: 3, acmod: 7, lfeon: 1)
        let cfg = EAC3.config(from: EAC3.frames(in: frame)[0].raw)
        XCTAssertEqual(cfg?.sampleRate, 24000)
        XCTAssertEqual(cfg?.channels, 6)             // acmod 7 (3/2) = 5 + LFE
    }

    func testDependentSubstreamJoinsIndependentUnit() {
        // An independent substream followed by a dependent one is a single access
        // unit (e.g. >5.1 / Atmos), handed to the decoder intact.
        let indep = TS.eac3Frame(sizeBytes: 100, strmtyp: 0)
        let dep = TS.eac3Frame(sizeBytes: 60, strmtyp: 1)
        let frames = EAC3.frames(in: indep + dep)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].raw.count, 160)
    }

    func testDemuxerPrefersDVBEAC3OverAC3() {
        // A DVB channel offering both Dolby tracks: AC-3 (desc 0x6A) and E-AC-3
        // (desc 0x7A). E-AC-3 outranks AC-3 and must be selected.
        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy

        let parser = TSPacketParser()
        let videoPID: UInt16 = 0x0100
        let ac3PID: UInt16 = 0x0101
        let eac3PID: UInt16 = 0x0102

        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true, payload: TS.pmt(
            videoPID: videoPID,
            audio: [(0x06, ac3PID, [0x6A, 0x01, 0x00]),     // DVB AC-3
                    (0x06, eac3PID, [0x7A, 0x01, 0x00])]))  // DVB E-AC-3
        stream += TS.packet(pid: eac3PID, payloadUnitStart: true,
                            payload: TS.pes(streamID: 0xBD, pts: 9000, payload: TS.eac3Frame()))

        for packet in parser.push(Data(stream)) { demuxer.consume(packet) }
        demuxer.flush()

        XCTAssertTrue(spy.hasAudio)
        XCTAssertEqual(spy.audioFormat?.codec, .eac3)
        XCTAssertEqual(spy.audioFormat?.sampleRate, 48000)
        XCTAssertEqual(spy.audioUnits.count, 1)
        XCTAssertEqual(spy.audioUnits.first?.pts, 9000)
    }

    func testDemuxerRoutesATSCEAC3StreamType() {
        // ATSC signals E-AC-3 with stream_type 0x87 (no descriptor needed).
        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy

        let parser = TSPacketParser()
        let eac3PID: UInt16 = 0x0101

        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true, payload: TS.pmt(
            videoPID: 0x0100, audio: [(0x87, eac3PID, [])]))
        stream += TS.packet(pid: eac3PID, payloadUnitStart: true,
                            payload: TS.pes(streamID: 0xBD, pts: 0, payload: TS.eac3Frame()))

        for packet in parser.push(Data(stream)) { demuxer.consume(packet) }
        demuxer.flush()

        XCTAssertEqual(spy.audioFormat?.codec, .eac3)
        XCTAssertEqual(spy.audioUnits.count, 1)
    }
}
