import XCTest
@testable import TStreamKit

/// Coverage for the HEVC and AC-3 passthrough parsers added alongside H.264/AAC.
final class CodecSupportTests: XCTestCase {

    // MARK: HEVC

    func testHEVCNALSplittingDropsParameterSetsAndFlagsKeyframe() {
        // VPS(32), SPS(33), PPS(34), IDR_W_RADL(19) — each behind a start code.
        let stream: [UInt8] = [
            0x00, 0x00, 0x01, 0x40, 0x01, 0xAA,        // VPS
            0x00, 0x00, 0x01, 0x42, 0x01, 0xBB, 0xCC,  // SPS
            0x00, 0x00, 0x01, 0x44, 0x01, 0xDD,        // PPS
            0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xEE,  // IDR slice (4-byte start code)
        ]
        let nals = HEVC.splitNALUnits(stream)
        XCTAssertEqual(nals.map(\.type), [32, 33, 34, 19])

        let sample = HEVC.sample(from: nals)
        XCTAssertTrue(sample.isKeyframe, "an IRAP picture must mark the sample as a keyframe")
        // Only the IDR NAL survives, as a 4-byte length prefix + 3 payload bytes.
        XCTAssertEqual([UInt8](sample.data), [0x00, 0x00, 0x00, 0x03, 0x26, 0x01, 0xEE])
    }

    func testHEVCCodecParametersString() {
        // Main profile, Main tier, level 9.3, one constraint byte set.
        var ptl = [UInt8](repeating: 0, count: 12)
        ptl[0] = 0x01                 // profile_space=0, tier=0, profile_idc=1
        ptl[1] = 0x60                 // compatibility flags (Main)
        ptl[5] = 0xB0                 // first constraint byte
        ptl[11] = 93                  // general_level_idc
        XCTAssertEqual(HEVC.codecParameters(generalProfileTierLevel: ptl), "hvc1.1.6.L93.B0")
    }

    // MARK: AC-3

    func testAC3FramingAndConfig() {
        // 32 kbps @ 48 kHz (frmsizecod 0 → 64 words → 128 bytes), stereo, no LFE.
        var frame = [UInt8](repeating: 0, count: 128)
        frame[0] = 0x0B; frame[1] = 0x77   // syncword
        frame[4] = 0x00                     // fscod=0 (48k), frmsizecod=0
        frame[5] = 0x40                     // bsid=8, bsmod=0
        frame[6] = 0x40                     // acmod=2 (stereo), dsurmod/lfe=0

        // Two back-to-back frames must both be recovered.
        let frames = AC3.frames(in: frame + frame)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].raw.count, 128)

        let cfg = AC3.config(from: frames[0].raw)
        XCTAssertEqual(cfg?.sampleRate, 48000)
        XCTAssertEqual(cfg?.channels, 2)
        XCTAssertEqual(cfg.map { [UInt8]($0.dac3) }, [0x10, 0x10, 0x00])
    }

    func testAC3IgnoresLeadingGarbageBeforeSync() {
        var frame = [UInt8](repeating: 0, count: 128)
        frame[0] = 0x0B; frame[1] = 0x77
        frame[4] = 0x00; frame[5] = 0x40; frame[6] = 0x40
        let frames = AC3.frames(in: [0x12, 0x34, 0x56] + frame)
        XCTAssertEqual(frames.count, 1)
    }
}
