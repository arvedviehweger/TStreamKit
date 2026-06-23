import XCTest
@testable import TStreamKit

final class DemuxerSpy: TSDemuxerDelegate {
    var videoFormat: VideoFormat?
    var audioFormat: AudioFormat?
    var videoUnits: [AccessUnit] = []
    var audioUnits: [AccessUnit] = []
    var hasVideo = false
    var hasAudio = false
    var errors: [TStreamError] = []
    var rawVideo: [(codec: VideoCodec, pts: UInt64)] = []

    func demuxer(_ d: TSDemuxer, didParseVideoFormat format: VideoFormat) { videoFormat = format }
    func demuxer(_ d: TSDemuxer, didParseAudioFormat format: AudioFormat) { audioFormat = format }
    func demuxer(_ d: TSDemuxer, didProduceVideo unit: AccessUnit) { videoUnits.append(unit) }
    func demuxer(_ d: TSDemuxer, didProduceAudio unit: AccessUnit) { audioUnits.append(unit) }
    func demuxer(_ d: TSDemuxer, didProduceRawVideo data: Data, codec: VideoCodec, pts: UInt64, dts: UInt64) {
        rawVideo.append((codec, pts))
    }
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
        // 4-byte length prefix + 4 IDR bytes (SPS/PPS live in the format
        // description / avcC, not the sample data).
        XCTAssertEqual([UInt8](sample.data), [0x00, 0x00, 0x00, 0x04, 0x65, 0x88, 0x99, 0xAA])
    }

    func testNonIDRISliceIsUsableAsLiveSyncSample() {
        // first_mb_in_slice=0 (ue "1"), slice_type=2/I-slice (ue "011").
        let nonIDRI: [UInt8] = [0x41, 0xB0]
        let nals = H264.splitNALUnits(TS.annexB([nonIDRI]))

        let sample = H264.avccSample(from: nals)

        XCTAssertTrue(sample.isKeyframe)
        XCTAssertTrue(sample.startsSegment)
        XCTAssertEqual(sample.syncType, .nonIDRIntra)
    }

    func testSEIOnlyNALDoesNotBecomeVideoSample() {
        let recoverySEI: [UInt8] = [0x06, 0x06, 0x01, 0x80]
        let nals = H264.splitNALUnits(TS.annexB([recoverySEI]))

        let sample = H264.avccSample(from: nals)

        XCTAssertTrue(sample.data.isEmpty)
        XCTAssertFalse(sample.isKeyframe)
        XCTAssertFalse(sample.startsSegment)
    }

    func testDVBAC3DescriptorIsPreferredOverMP2() {
        // ZDF-HD-style PMT: MPEG audio (0x03) listed first, Dolby AC-3 carried as
        // a private stream (0x06) with a DVB AC-3 descriptor (tag 0x6A). The AC-3
        // track must be selected over the MP2 one.
        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy

        let parser = TSPacketParser()
        let videoPID: UInt16 = 0x0100
        let mp2PID: UInt16 = 0x0101
        let ac3PID: UInt16 = 0x0102

        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true, payload: TS.pmt(
            videoPID: videoPID,
            audio: [(0x03, mp2PID, []),                 // MPEG-1 Layer II
                    (0x06, ac3PID, [0x6A, 0x01, 0x00])] // DVB AC-3 descriptor
        ))
        stream += TS.packet(pid: ac3PID, payloadUnitStart: true,
                            payload: TS.pes(streamID: 0xBD, pts: 9000, payload: TS.ac3Frame()))

        for packet in parser.push(Data(stream)) { demuxer.consume(packet) }
        demuxer.flush()

        XCTAssertTrue(spy.hasAudio)
        XCTAssertEqual(spy.audioFormat?.codec, .ac3)
        XCTAssertEqual(spy.audioFormat?.sampleRate, 48000)
        XCTAssertEqual(spy.audioUnits.count, 1)
        XCTAssertEqual(spy.audioUnits.first?.pts, 9000)
    }

    func testMPEG2VideoStreamTypeIsRoutedAsRawVideo() {
        // MPEG-2 video (stream_type 0x02) — worldwide SD and US ATSC. In raw-video
        // mode the demuxer forwards the PES payload tagged as .mpeg2 for libavcodec.
        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy
        demuxer.rawVideoMode = true

        let parser = TSPacketParser()
        let videoPID: UInt16 = 0x0100

        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true, payload: TS.pmt(
            videoPID: videoPID, videoStreamType: 0x02,
            audio: [(0x03, 0x0101, [])]))
        // Raw mode forwards the PES payload verbatim; contents need not be valid MPEG-2.
        stream += TS.packet(pid: videoPID, payloadUnitStart: true,
                            payload: TS.pes(streamID: 0xE0, pts: 9000, payload: [0x00, 0x00, 0x01, 0xB3]))

        for packet in parser.push(Data(stream)) { demuxer.consume(packet) }
        demuxer.flush()

        XCTAssertTrue(spy.hasVideo)
        XCTAssertEqual(spy.rawVideo.count, 1)
        XCTAssertEqual(spy.rawVideo.first?.codec, .mpeg2)
        XCTAssertEqual(spy.rawVideo.first?.pts, 9000)
    }

    func testDVBPrivateStreamWithoutAC3DescriptorIsNotAudio() {
        // A 0x06 private stream with no AC-3 descriptor (e.g. teletext/subtitles)
        // must not be mistaken for audio.
        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy

        let parser = TSPacketParser()
        var stream: [UInt8] = []
        stream += TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true, payload: TS.pmt(
            videoPID: 0x0100,
            audio: [(0x06, 0x0102, [0x56, 0x01, 0x00])] // teletext_descriptor (0x56)
        ))

        for packet in parser.push(Data(stream)) { demuxer.consume(packet) }

        XCTAssertTrue(spy.hasVideo)
        XCTAssertFalse(spy.hasAudio)
    }

    func testContinuityGapDropsCorruptVideoPES() {
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
        stream += TS.packet(pid: videoPID, payloadUnitStart: true, continuityCounter: 0,
                            payload: TS.pes(streamID: 0xE0, pts: 9000, payload: video))
        stream += TS.packet(pid: videoPID, payloadUnitStart: true, continuityCounter: 2,
                            payload: TS.pes(streamID: 0xE0, pts: 12000, payload: video))

        for packet in parser.push(Data(stream)) {
            demuxer.consume(packet)
        }
        demuxer.flush()

        XCTAssertEqual(spy.videoUnits.count, 1)
        XCTAssertEqual(spy.videoUnits.first?.pts, 12000)
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

    func testFieldInfoParsesPAFFFields() {
        // Slice header bits (log2MaxFrameNum=4): first_mb=0 ("1"),
        // slice_type=I ("011"), pps_id=0 ("1"), frame_num=5 ("0101"),
        // field_pic_flag=1, bottom_field_flag=0 → top, =1 → bottom.
        let top = H264.splitNALUnits(TS.annexB([[0x41, 0xBA, 0xC0]]))
        let bottom = H264.splitNALUnits(TS.annexB([[0x41, 0xBA, 0xE0]]))

        let topInfo = H264.fieldInfo(fromFirstSlice: top, log2MaxFrameNum: 4)
        let bottomInfo = H264.fieldInfo(fromFirstSlice: bottom, log2MaxFrameNum: 4)

        XCTAssertEqual(topInfo?.fieldPicture, true)
        XCTAssertEqual(topInfo?.bottomField, false)
        XCTAssertEqual(topInfo?.frameNum, 5)
        XCTAssertEqual(bottomInfo?.fieldPicture, true)
        XCTAssertEqual(bottomInfo?.bottomField, true)
        XCTAssertEqual(bottomInfo?.frameNum, 5)
    }

    func testFieldInfoDetectsFramePicture() {
        // Same header but field_pic_flag=0 → a frame picture, not a field.
        let frame = H264.splitNALUnits(TS.annexB([[0x41, 0xBA, 0x80]]))
        let info = H264.fieldInfo(fromFirstSlice: frame, log2MaxFrameNum: 4)
        XCTAssertEqual(info?.fieldPicture, false)
        XCTAssertEqual(info?.frameNum, 5)
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
