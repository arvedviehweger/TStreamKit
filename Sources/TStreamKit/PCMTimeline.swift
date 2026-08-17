import Foundation

/// Places decoded PCM on a continuous timeline of its own.
///
/// Container timestamps are quantised: Matroska stores milliseconds, and a
/// transport stream puts one PTS on a whole PES, while a 1024 sample frame at
/// 48 kHz lasts 21.3 ms. Compressed packets survive that, because the renderer
/// decodes them into one stream. PCM does not: every buffer is laid down at
/// exactly the time it is given, so rounded timestamps leave a fraction of a
/// millisecond of gap or overlap at each buffer edge, heard as a click at the
/// frame rate.
///
/// So the sample count sets the pace, anchored to the first block. The
/// projection is recomputed from the running total rather than added up, which
/// keeps integer division from drifting over a long stream.
struct PCMTimeline {
    /// The rate the decoder actually produces. Set before the first stamp.
    var sampleRate = 48_000

    private var anchor: UInt64?
    private var samples: UInt64 = 0

    /// Quarter of a second. Comfortably past any rounding, well short of a seek.
    private static let resyncTicks: Int64 = 90_000 / 4

    /// Forgets the anchor, so the next block starts a new timeline.
    mutating func reset() {
        anchor = nil
        samples = 0
    }

    /// The 90 kHz time to lay a block of `frames` samples down at, given the
    /// time the container put on the packet it was decoded from.
    mutating func stamp(container pts: UInt64, frames: Int) -> UInt64 {
        let rate = UInt64(max(sampleRate, 1))
        guard let start = anchor else {
            anchor = pts
            samples = UInt64(max(frames, 0))
            return pts
        }
        let projected = start + samples * 90_000 / rate
        // A container that has genuinely moved, after a seek or a gap in the
        // stream, has to win. Only rounding is absorbed.
        if abs(Int64(bitPattern: projected) - Int64(bitPattern: pts)) > Self.resyncTicks {
            anchor = pts
            samples = UInt64(max(frames, 0))
            return pts
        }
        samples += UInt64(max(frames, 0))
        return projected
    }
}
