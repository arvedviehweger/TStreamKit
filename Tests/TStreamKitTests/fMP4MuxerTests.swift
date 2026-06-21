import XCTest
@testable import TStreamKit

final class fMP4MuxerTests: XCTestCase {
    private func makeMuxer(withAudio: Bool = true) -> FMP4Muxer {
        let video = VideoFormat(codec: .h264,
                                vps: Data(),
                                sps: Data([0x67, 0x42, 0x00, 0x1F, 0x96]),
                                pps: Data([0x68, 0xCE, 0x3C, 0x80]),
                                width: 1280, height: 720,
                                codecParameters: "avc1.42001f",
                                hevc: nil)
        let audio = withAudio
            ? AudioFormat(codec: .aac, sampleRate: 44100, channels: 2,
                          samplesPerFrame: 1024, decoderConfig: Data([0x12, 0x10]))
            : nil
        return FMP4Muxer(video: video, audio: audio)
    }

    func testInitializationSegmentStructure() {
        let initSegment = makeMuxer().initializationSegment()

        let boxes = topLevelBoxes(initSegment)
        XCTAssertEqual(boxes, ["ftyp", "moov"], "init segment must be exactly ftyp + moov with valid sizes")

        for fourCC in ["mvhd", "trak", "tkhd", "mdia", "minf", "stbl", "avc1", "avcC", "mp4a", "esds", "mvex", "trex"] {
            XCTAssertTrue(dataContains(initSegment, fourCC: fourCC), "missing box \(fourCC)")
        }
    }

    func testInitializationSegmentWithoutAudioHasNoAudioBoxes() {
        let initSegment = makeMuxer(withAudio: false).initializationSegment()
        XCTAssertTrue(dataContains(initSegment, fourCC: "avc1"))
        XCTAssertFalse(dataContains(initSegment, fourCC: "mp4a"))
    }

    func testFragmentEmittedOnKeyframeBoundary() {
        let muxer = makeMuxer()
        var fragments: [Data] = []
        muxer.onSegment = { data, _ in fragments.append(data) }

        muxer.addVideo(AccessUnit(data: Data([0, 0, 0, 2, 0x65, 0x01]), pts: 0, dts: 0, isKeyframe: true))
        muxer.addAudio(AccessUnit(data: Data([0x01, 0x02]), pts: 0, dts: 0, isKeyframe: true))
        muxer.addVideo(AccessUnit(data: Data([0, 0, 0, 2, 0x41, 0x02]), pts: 3000, dts: 3000, isKeyframe: false))
        // Second keyframe closes the first GOP and emits a fragment.
        muxer.addVideo(AccessUnit(data: Data([0, 0, 0, 2, 0x65, 0x03]), pts: 6000, dts: 6000, isKeyframe: true))

        XCTAssertEqual(fragments.count, 1)
        let fragment = fragments[0]
        XCTAssertEqual(topLevelBoxes(fragment), ["styp", "sidx", "moof", "mdat"],
                       "HLS fMP4 segment must be styp + sidx + moof + mdat with valid sizes")
        for fourCC in ["mfhd", "traf", "tfhd", "tfdt", "trun"] {
            XCTAssertTrue(dataContains(fragment, fourCC: fourCC), "missing box \(fourCC)")
        }
    }

    func testFinishFlushesRemaining() {
        let muxer = makeMuxer(withAudio: false)
        var fragments: [Data] = []
        muxer.onSegment = { data, _ in fragments.append(data) }

        muxer.addVideo(AccessUnit(data: Data([0, 0, 0, 2, 0x65, 0x01]), pts: 0, dts: 0, isKeyframe: true))
        XCTAssertEqual(fragments.count, 0, "single GOP stays buffered until finish")
        muxer.finish()
        XCTAssertEqual(fragments.count, 1)
    }
}
