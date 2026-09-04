import Foundation

/// Identifies the container in the leading bytes and runs the matching demuxer.
///
/// Shared by every source, because what the bytes *are* has nothing to do with
/// where they came from: the network path and the local-file path detect and
/// demux identically.
///
/// Detection happens on the live byte stream rather than through a separate
/// probe pass. A transcoding server starts a session per connection, so opening
/// a second one to sniff would both cost a round trip and leave a stray session
/// behind.
///
/// Confined to the owning source's queue.
final class ContainerPipeline {
    weak var output: StreamDemuxerOutput?
    /// Reports a container that could not be identified. Failures raised by the
    /// demuxer itself go straight to `output`.
    var onFail: ((TStreamError) -> Void)?

    /// Bytes held back until the container is known, then replayed into the
    /// demuxer. Empty once detection has finished.
    private var probeBuffer: [UInt8] = []
    private var demuxer: StreamDemuxer?
    private(set) var format: ContainerFormat?

    /// Whether the container has been identified. Seeking into a stream we
    /// never recognised is meaningless.
    var isIdentified: Bool { format != nil }

    func consume(_ data: Data) {
        if let demuxer {
            demuxer.consume(data)
            return
        }

        probeBuffer.append(contentsOf: data)
        guard let detected = ContainerFormat.detect(probeBuffer) else {
            if probeBuffer.count >= ContainerFormat.probeLimit {
                onFail?(.demux("could not identify the container in the first \(probeBuffer.count) bytes"))
            }
            return
        }

        let made = makeDemuxer(for: detected)
        made.output = output
        format = detected
        demuxer = made
        TStreamDiagnostics.log("source: detected \(Self.describe(detected)) container")

        let buffered = Data(probeBuffer)
        probeBuffer.removeAll(keepingCapacity: false)
        made.consume(buffered)
    }

    func reset() { demuxer?.reset() }
    func finish() { demuxer?.finish() }

    func stop() {
        demuxer?.stop()
        demuxer = nil
        probeBuffer.removeAll()
        output = nil
        onFail = nil
    }

    private func makeDemuxer(for format: ContainerFormat) -> StreamDemuxer {
        switch format {
        case .mpegTS: return TSStreamDemuxer()
        case .matroska, .mp4: return FFStreamDemuxer()
        }
    }

    private static func describe(_ format: ContainerFormat) -> String {
        switch format {
        case .mpegTS: return "MPEG-TS"
        case .matroska: return "Matroska/WebM"
        case .mp4: return "MP4"
        }
    }
}
