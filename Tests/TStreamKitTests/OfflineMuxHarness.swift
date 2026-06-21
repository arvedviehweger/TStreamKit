import XCTest
@testable import TStreamKit

/// Offline bring-up harness: drives a real `.ts` file through the full
/// parser → demuxer → muxer pipeline and writes the resulting fMP4 to disk so it
/// can be inspected with `ffprobe` / AVFoundation.
///
/// Run with:
///   TSREAM_TS_INPUT=/tmp/tstream_sample.ts TSREAM_FMP4_OUTPUT=/tmp/out.mp4 \
///   swift test --filter OfflineMuxHarness/testConvertTSToFMP4
final class OfflineMuxHarness: XCTestCase {
    private final class Collector: TSDemuxerDelegate {
        var muxer: FMP4Muxer?
        var output = Data()
        var videoFormat: VideoFormat?
        var audioFormat: AudioFormat?
        var expectsAudio = false
        var identified = false
        var pendingVideo: [AccessUnit] = []
        var pendingAudio: [AccessUnit] = []
        var videoCount = 0
        var audioCount = 0

        func demuxer(_ d: TSDemuxer, didIdentifyStreamsHasVideo v: Bool, hasAudio a: Bool) {
            identified = true; expectsAudio = a; build()
        }
        func demuxer(_ d: TSDemuxer, didParseVideoFormat format: VideoFormat) { videoFormat = format; build() }
        func demuxer(_ d: TSDemuxer, didParseAudioFormat format: AudioFormat) { audioFormat = format; build() }
        func demuxer(_ d: TSDemuxer, didProduceVideo unit: AccessUnit) {
            videoCount += 1
            if let muxer { muxer.addVideo(unit) } else { pendingVideo.append(unit) }
        }
        func demuxer(_ d: TSDemuxer, didProduceAudio unit: AccessUnit) {
            audioCount += 1
            if let muxer { muxer.addAudio(unit) } else { pendingAudio.append(unit) }
        }
        func demuxer(_ d: TSDemuxer, didFail error: TStreamError) { print("demux fail:", error) }

        private func build() {
            guard muxer == nil, let videoFormat else { return }
            guard audioFormat != nil || (identified && !expectsAudio) else { return }
            let muxer = FMP4Muxer(video: videoFormat, audio: audioFormat)
            muxer.onSegment = { [weak self] data, _ in self?.output.append(data) }
            self.muxer = muxer
            output.append(muxer.initializationSegment())
            for u in pendingVideo { muxer.addVideo(u) }
            for u in pendingAudio { muxer.addAudio(u) }
            pendingVideo.removeAll(); pendingAudio.removeAll()
        }
    }

    /// Dumps the HLS output (index.m3u8 + init.mp4 + segmentN.m4s) to a
    /// directory so it can be validated with ffmpeg / mediastreamvalidator.
    func testDumpHLS() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inputPath = env["TSREAM_TS_INPUT"], let dir = env["TSREAM_HLS_DIR"] else {
            throw XCTSkip("Set TSREAM_TS_INPUT and TSREAM_HLS_DIR.")
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let tsData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let parser = TSPacketParser()
        let demuxer = TSDemuxer()
        let store = HLSStore(windowSize: 1_000)

        final class Sink: TSDemuxerDelegate {
            var muxer: FMP4Muxer?
            let store: HLSStore
            var vf: VideoFormat?; var af: AudioFormat?; var expectsAudio = false; var identified = false
            var pv: [AccessUnit] = []; var pa: [AccessUnit] = []
            init(_ s: HLSStore) { store = s }
            func demuxer(_ d: TSDemuxer, didIdentifyStreamsHasVideo v: Bool, hasAudio a: Bool) { identified = true; expectsAudio = a; build() }
            func demuxer(_ d: TSDemuxer, didParseVideoFormat f: VideoFormat) { vf = f; build() }
            func demuxer(_ d: TSDemuxer, didParseAudioFormat f: AudioFormat) { af = f; build() }
            func demuxer(_ d: TSDemuxer, didProduceVideo u: AccessUnit) { if let m = muxer { m.addVideo(u) } else { pv.append(u) } }
            func demuxer(_ d: TSDemuxer, didProduceAudio u: AccessUnit) { if let m = muxer { m.addAudio(u) } else { pa.append(u) } }
            func demuxer(_ d: TSDemuxer, didFail e: TStreamError) {}
            func build() {
                guard muxer == nil, let vf else { return }
                guard af != nil || (identified && !expectsAudio) else { return }
                let m = FMP4Muxer(video: vf, audio: af)
                m.onSegment = { [store] data, dur in store.addSegment(data, duration: dur) }
                muxer = m
                store.setInitSegment(m.initializationSegment())
                pv.forEach(m.addVideo); pa.forEach(m.addAudio); pv = []; pa = []
            }
        }
        let sink = Sink(store)
        demuxer.delegate = sink
        for packet in parser.push(tsData) { demuxer.consume(packet) }
        demuxer.flush(); sink.muxer?.finish()

        try store.initSegment?.write(to: URL(fileURLWithPath: "\(dir)/init.mp4"))
        var seq = 0
        while let data = store.segmentData(forSequence: seq) {
            try data.write(to: URL(fileURLWithPath: "\(dir)/segment\(seq).m4s"))
            seq += 1
        }
        try store.mediaPlaylist().write(toFile: "\(dir)/index.m3u8", atomically: true, encoding: .utf8)
        print("HLS: wrote init + \(seq) segments + playlist to \(dir)")
    }

    func testConvertTSToFMP4() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inputPath = env["TSREAM_TS_INPUT"] else {
            throw XCTSkip("Set TSREAM_TS_INPUT to run the offline harness.")
        }
        let outputPath = env["TSREAM_FMP4_OUTPUT"] ?? "/tmp/tstream_out.mp4"

        let tsData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let parser = TSPacketParser()
        let demuxer = TSDemuxer()
        let collector = Collector()
        demuxer.delegate = collector

        // Feed in realistic network-sized chunks to exercise buffering.
        let chunkSize = 4096
        var offset = 0
        while offset < tsData.count {
            let end = min(offset + chunkSize, tsData.count)
            for packet in parser.push(tsData.subdata(in: offset..<end)) {
                demuxer.consume(packet)
            }
            offset = end
        }
        demuxer.flush()
        collector.muxer?.finish()

        print("HARNESS: video AUs \(collector.videoCount), audio AUs \(collector.audioCount), fMP4 \(collector.output.count) bytes")
        print("HARNESS: video format \(String(describing: collector.videoFormat.map { "\($0.width)x\($0.height)" }))")
        print("HARNESS: audio format \(String(describing: collector.audioFormat.map { "\($0.sampleRate)Hz \($0.channels)ch" }))")

        try collector.output.write(to: URL(fileURLWithPath: outputPath))
        print("HARNESS: wrote \(outputPath)")

        XCTAssertGreaterThan(collector.output.count, 0)
        XCTAssertNotNil(collector.videoFormat)
    }
}
