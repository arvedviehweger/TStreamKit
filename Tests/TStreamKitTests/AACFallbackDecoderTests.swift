import CFFVideoDecoder
import XCTest
@testable import TStreamKit

/// The fallback for AAC profiles Core Audio turns down is only real if
/// libavcodec in this build carries an AAC decoder. It is left out of the build
/// on purpose for everything else, so this is worth pinning.
final class AACFallbackDecoderTests: XCTestCase {

    func testADecoderOpensForTheProfileTheSystemRefuses() throws {
        // AAC Main, 48000 Hz, stereo: the config a transcoding server sent us.
        let decoder = try XCTUnwrap(
            TStreamFFAudioDecoder(codec: CFF_AUDIO_AAC, sampleRate: 48000, channels: 2,
                                  extradata: Data([0x09, 0x90])),
            "libavcodec has no AAC decoder in this build")
        XCTAssertEqual(decoder.sampleRate, 48000)
        XCTAssertEqual(decoder.channels, 2)
    }

    /// Opening a decoder is not the same as getting audio out of it, so run a
    /// real bitstream through and check PCM arrives.
    func testRealFramesDecodeToPCM() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/probe", withExtension: "adts"),
                                "fixture probe.adts is missing")
        let frames = Self.rawFrames(in: try Data(contentsOf: url))
        XCTAssertGreaterThan(frames.count, 5, "fixture carries too little audio to be a test")

        // 48000 Hz mono AAC-LC, matching how the fixture was encoded.
        let decoder = try XCTUnwrap(
            TStreamFFAudioDecoder(codec: CFF_AUDIO_AAC, sampleRate: 48000, channels: 1,
                                  extradata: Data([0x11, 0x88])))

        var bytes = 0
        for (index, frame) in frames.enumerated() {
            for block in decoder.decode(frame, pts: UInt64(index) * 1024) {
                bytes += block.data.count
            }
        }
        XCTAssertGreaterThan(bytes, 0, "the decoder produced no audio at all")
        // Interleaved 16 bit mono, so two bytes a sample. Allow for the decoder
        // holding back a frame; anything near the input length proves the path.
        let expected = frames.count * 1024 * 2
        XCTAssertGreaterThan(bytes, expected / 2, "far less audio came out than went in")
    }

    /// The refusal has to be caught on the MPEG-TS path too, not only in the
    /// containers libavformat reads: a tvheadend `webtv-h264-aac-mpegts`
    /// profile serves the same AAC the matroska one does, and it played its
    /// video in silence.
    func testTransportStreamAACTheSystemRefusesArrivesAsPCM() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/probe", withExtension: "adts"),
                                "fixture probe.adts is missing")
        let payloads = Self.rawFrames(in: try Data(contentsOf: url))
        XCTAssertGreaterThan(payloads.count, 5, "fixture carries too little audio to be a test")

        let spy = DemuxerSpy()
        let demuxer = TSDemuxer()
        demuxer.delegate = spy
        let parser = TSPacketParser()
        let audioPID: UInt16 = 0x0101

        var stream = TS.packet(pid: 0x0000, payloadUnitStart: true, payload: TS.pat(pmtPID: 0x1000))
        stream += TS.packet(pid: 0x1000, payloadUnitStart: true,
                            payload: TS.radioPMT(audioPID: audioPID, streamType: 0x0F))
        var counter: UInt8 = 0
        for (index, payload) in payloads.enumerated() {
            // 48 kHz mono, labelled AAC Main: what the transcoding server sends.
            let frame = TS.adts(payload: [UInt8](payload), sampleRateIndex: 3, channels: 1, profile: 0)
            let pes = TS.pes(streamID: 0xC0, pts: 9000 + UInt64(index) * 1920, payload: frame)
            stream += TS.packets(pid: audioPID, pes: pes, continuityCounter: &counter)
        }

        for packet in parser.push(Data(stream)) { demuxer.consume(packet) }
        demuxer.flush()

        // Compressed frames would reach a renderer that cannot decode them, and
        // the stream would play silently. Decoded PCM is the whole point.
        XCTAssertEqual(spy.audioFormat?.codec, .pcm)
        XCTAssertEqual(spy.audioFormat?.sampleRate, 48000)
        XCTAssertEqual(spy.audioFormat?.channels, 1)
        XCTAssertFalse(spy.audioUnits.isEmpty, "no audio came out of the fallback decoder")
        // Interleaved 16 bit mono, so two bytes a sample. Allow for the decoder
        // holding back a frame; anything near the input length proves the path.
        let bytes = spy.audioUnits.reduce(0) { $0 + $1.data.count }
        XCTAssertGreaterThan(bytes, payloads.count * 1024 * 2 / 2, "far less audio came out than went in")

        // PCM is laid down where it is stamped, so the stamps have to advance.
        let stamps = spy.audioUnits.map(\.pts)
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertGreaterThan(stamps.last ?? 0, stamps.first ?? 0)
    }

    /// Splits an ADTS file into the raw frames a container would hand us.
    private static func rawFrames(in data: Data) -> [Data] {
        var frames: [Data] = []
        var i = 0
        while i + 7 <= data.count, data[i] == 0xFF, (data[i + 1] & 0xF0) == 0xF0 {
            let length = (Int(data[i + 3] & 0x03) << 11) | (Int(data[i + 4]) << 3) | (Int(data[i + 5]) >> 5)
            let header = (data[i + 1] & 0x01) == 1 ? 7 : 9
            guard length > header, i + length <= data.count else { break }
            frames.append(data.subdata(in: (i + header)..<(i + length)))
            i += length
        }
        return frames
    }
}
