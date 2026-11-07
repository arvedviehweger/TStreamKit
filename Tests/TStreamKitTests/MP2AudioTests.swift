import XCTest
@testable import TStreamKit

final class MP2AudioTests: XCTestCase {
    func testParsesLayerIIHeader() {
        // MPEG-1 Layer II, 48 kHz, 128 kbps, stereo, no padding.
        let header: [UInt8] = [0xFF, 0xFD, 0x84, 0x00]
        let h = MPEGAudio.parseHeader(header, 0)
        XCTAssertEqual(h?.sampleRate, 48000)
        XCTAssertEqual(h?.channels, 2)
        XCTAssertEqual(h?.frameLength, 384)   // 144 * 128000 / 48000
        XCTAssertEqual(h?.samplesPerFrame, 1152)
    }

    func testRejectsLayerIIIHeader() {
        // Same but layer bits = 01 (Layer III / MP3) → not handled here.
        let layerIII: [UInt8] = [0xFF, 0xFB, 0x84, 0x00]
        XCTAssertNil(MPEGAudio.parseHeader(layerIII, 0))
    }

    func testNextSyncSkipsLeadingBytes() {
        let buf: [UInt8] = [0x00, 0x12, 0xFF, 0xFD, 0x84, 0x00]
        XCTAssertEqual(MPEGAudio.nextSync(buf, from: 0), 2)
        XCTAssertNil(MPEGAudio.nextSync([0x00, 0x01, 0x02], from: 0))
    }

    func testAudioSpecificConfigMatchesAACLC() {
        // AAC-LC ASC: objectType=2, sampleRateIndex, channelConfig.
        XCTAssertEqual([UInt8](MP2Transcoder.audioSpecificConfig(sampleRate: 48000, channels: 2)), [0x11, 0x90])
        XCTAssertEqual([UInt8](MP2Transcoder.audioSpecificConfig(sampleRate: 44100, channels: 2)), [0x12, 0x10])
    }
}

final class MP2TranscoderTimelineTests: XCTestCase {
    /// 384-byte frames, each 1152 samples = 2160 ticks at 48 kHz.
    private let frameBytes = 384
    private let frameTicks: UInt64 = 2160
    private let start: UInt64 = 900_000

    private func frames() throws -> [[UInt8]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/probe", withExtension: "mp2"))
        let bytes = try [UInt8](Data(contentsOf: url))
        return stride(from: 0, to: bytes.count - frameBytes + 1, by: frameBytes).map {
            Array(bytes[$0..<($0 + frameBytes)])
        }
    }

    /// Feeds `frames` as PES of `perPES` frames each, stamped with the stream
    /// time of their first frame, leaving out the PES numbered in `dropping`.
    private func transcode(_ frames: [[UInt8]], perPES: Int, dropping: Set<Int> = [],
                           split: Bool = false) -> [UInt64] {
        let transcoder = MP2Transcoder()
        var stamps: [UInt64] = []
        transcoder.onAAC = { _, pts in stamps.append(pts) }
        // `split` cuts each PES half a frame early, carrying the rest over, the
        // way a PES boundary can fall mid-frame.
        var bytes: [UInt8] = []
        for f in frames { bytes += f }
        var offset = 0
        var index = 0
        while offset < bytes.count {
            let firstFrame = index * perPES
            var end = min(offset + perPES * frameBytes, bytes.count)
            if split, end < bytes.count { end -= frameBytes / 2 }
            // A PES is stamped with the first frame *starting* in it.
            let firstStart = (offset + frameBytes - 1) / frameBytes
            let pts = start + UInt64(split ? firstStart : firstFrame) * frameTicks
            if !dropping.contains(index) { transcoder.consume(Array(bytes[offset..<end]), pts: pts) }
            offset = end
            index += 1
        }
        return stamps
    }

    func testCleanStreamIsContinuous() throws {
        let stamps = transcode(try frames(), perPES: 2)
        XCTAssertGreaterThan(stamps.count, 80)
        XCTAssertEqual(stamps.first, start)
        for (a, b) in zip(stamps, stamps.dropFirst()) { XCTAssertEqual(b - a, 1920) }
    }

    /// A PES lost to a continuity gap must leave a gap of the same length —
    /// otherwise every later packet plays early, and the frame cut off at the
    /// loss gets glued to the next PES and decodes as noise.
    func testLostPESIsBridgedOnTheStreamClock() throws {
        let all = try frames()
        let clean = transcode(all, perPES: 2, split: true)
        let lossy = transcode(all, perPES: 2, dropping: [10], split: true)
        // Still one continuous run of packets…
        for (a, b) in zip(lossy, lossy.dropFirst()) { XCTAssertEqual(b - a, 1920) }
        // …that covers the same stretch of stream time as the clean one.
        let cleanEnd = try XCTUnwrap(clean.last), lossyEnd = try XCTUnwrap(lossy.last)
        XCTAssertLessThanOrEqual(abs(Int64(cleanEnd) - Int64(lossyEnd)), 1920)
    }

    func testJumpRestartsTheTimeline() throws {
        let all = try frames()
        let transcoder = MP2Transcoder()
        var stamps: [UInt64] = []
        transcoder.onAAC = { _, pts in stamps.append(pts) }
        for (i, pair) in stride(from: 0, to: 40, by: 2).enumerated() {
            transcoder.consume(all[pair] + all[pair + 1], pts: start + UInt64(i) * 2 * frameTicks)
        }
        let before = stamps.count
        let later: UInt64 = 90_000 * 60
        for (i, pair) in stride(from: 40, to: 80, by: 2).enumerated() {
            transcoder.consume(all[pair] + all[pair + 1], pts: later + UInt64(i) * 2 * frameTicks)
        }
        let after = Array(stamps[before...])
        XCTAssertEqual(after.first, later)
    }
}
