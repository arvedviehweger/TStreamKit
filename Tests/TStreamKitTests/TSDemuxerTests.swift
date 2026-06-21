import XCTest
@testable import TStreamKit

private final class DemuxerSpy: TSDemuxerDelegate {
    var videoFormat: VideoFormat?
    var audioFormat: AudioFormat?
    var videoUnits: [AccessUnit] = []
    var audioUnits: [AccessUnit] = []
    var hasVideo = false
    var hasAudio = false
    var errors: [TStreamError] = []

    func demuxer(_ d: TSDemuxer, didParseVideoFormat format: VideoFormat) { videoFormat = format }
    func demuxer(_ d: TSDemuxer, didParseAudioFormat format: AudioFormat) { audioFormat = format }
    func demuxer(_ d: TSDemuxer, didProduceVideo unit: AccessUnit) { videoUnits.append(unit) }
    func demuxer(_ d: TSDemuxer, didProduceAudio unit: AccessUnit) { audioUnits.append(unit) }
    func demuxer(_ d: TSDemuxer, didFail error: TStreamError) { errors.append(error) }
    func demuxer(_ d: TSDemuxer, didIdentifyStreamsHasVideo v: Bool, hasAudio a: Bool) {
        hasVideo = v; hasAudio = a
    }
}

final class TSDemuxerTests: XCTestCase {
    func testNALSplittingAndAVCC() {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0x96]
        let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
        let idr: [UInt8] = [0x65, 0x88, 0x99, 0xAA]
        let stream = TS.annexB([sps, pps, idr])

        let nals = H264.splitNALUnits(stream)
        XCTAssertEqual(nals.map { $0.type }, [7, 8, 5])

        let sample = H264.avccSample(from: nals)
        XCTAssertTrue(sample.isKeyframe)
        // 4-byte length prefix + 4 IDR bytes (SPS/PPS dropped).
        XCTAssertEqual([UInt8](sample.data), [0x00, 0x00, 0x00, 0x04, 0x65, 0x88, 0x99, 0xAA])
    }

    func testADTSFramingAndConfig() {
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let frames = ADTS.frames(in: TS.adts(payload: payload))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual([UInt8](frames[0].raw), payload)
        XCTAssertEqual(frames[0].sampleRateIndex, 4)
        XCTAssertEqual(frames[0].channelConfig, 2)

        let config = ADTS.config(from: frames[0])
        XCTAssertEqual(config.sampleRate, 44100)
        XCTAssertEqual(config.channels, 2)
        XCTAssertEqual([UInt8](config.audioSpecificConfig), [0x12, 0x10])
    }

    func testEndToEndDemux() {
        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy

        let parser = TSPacketParser()
        let videoPID: UInt16 = 0x0100
        let audioPID: UInt16 = 0x0101

        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true, payload: TS.pmt(videoPID: videoPID, audioPID: audioPID))

        let video = TS.annexB([[0x67, 0x42, 0x00, 0x1F, 0x96], [0x68, 0xCE, 0x3C, 0x80], [0x65, 0x01, 0x02]])
        stream += TS.packet(pid: videoPID, payloadUnitStart: true, payload: TS.pes(streamID: 0xE0, pts: 9000, payload: video))

        let audio = TS.adts(payload: [0x01, 0x02, 0x03, 0x04])
        stream += TS.packet(pid: audioPID, payloadUnitStart: true, payload: TS.pes(streamID: 0xC0, pts: 9000, payload: audio))

        for packet in parser.push(Data(stream)) {
            demuxer.consume(packet)
        }
        demuxer.flush()

        XCTAssertTrue(spy.hasVideo)
        XCTAssertTrue(spy.hasAudio)
        XCTAssertEqual(spy.videoFormat?.codec, .h264)
        XCTAssertEqual(spy.audioFormat?.codec, .aac)
        XCTAssertEqual(spy.audioFormat?.sampleRate, 44100)
        XCTAssertEqual(spy.videoUnits.count, 1)
        XCTAssertEqual(spy.videoUnits.first?.pts, 9000)
        XCTAssertTrue(spy.videoUnits.first?.isKeyframe ?? false)
        XCTAssertGreaterThanOrEqual(spy.audioUnits.count, 1)
        XCTAssertTrue(spy.errors.isEmpty)
    }
}
