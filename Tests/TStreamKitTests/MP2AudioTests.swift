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
