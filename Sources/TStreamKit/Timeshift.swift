import Foundation

/// Enables the rewindable live buffer on a `TStreamPlayerView`.
///
/// A live stream normally flows straight from the network into the decoder and
/// is gone once played. With a configuration attached, TStreamKit also records
/// every compressed access unit to a disk ring, which is what lets the viewer
/// pause live TV and skip back into what has already aired.
///
/// The buffer costs disk, not memory: it holds compressed units, so a full hour
/// of HD broadcast fits in roughly a gigabyte. It lives in the caches directory
/// by default and is deleted when playback stops.
public struct TStreamTimeshiftConfiguration: Sendable, Equatable {
    /// How far back the viewer can skip.
    public var maximumDuration: TimeInterval
    /// Ceiling on disk use. Whichever limit is reached first trims the oldest
    /// end of the buffer.
    public var maximumBytes: Int
    /// Where to keep the ring. `nil` uses the caches directory.
    public var storageDirectory: URL?

    public init(maximumDuration: TimeInterval = 3600,
                maximumBytes: Int = 1_500_000_000,
                storageDirectory: URL? = nil) {
        self.maximumDuration = maximumDuration
        self.maximumBytes = maximumBytes
        self.storageDirectory = storageDirectory
    }
}

/// What the live buffer currently offers, reported on the main thread.
public struct TStreamTimeshiftStatus: Sendable, Equatable {
    /// False when the buffer could not be created or was dropped after an I/O
    /// failure — the stream still plays, it just can't be rewound.
    public let isAvailable: Bool
    /// How far the picture lags the live edge. Zero while playing live.
    public let delaySeconds: TimeInterval
    /// How much further back the viewer can still skip from here.
    public let rewindableSeconds: TimeInterval
    /// Whether the player is being fed straight from the network. Goes false
    /// the moment playback is paused or rewound, and true again once replay
    /// catches back up with the broadcast.
    public let isAtLiveEdge: Bool

    public static let unavailable = TStreamTimeshiftStatus(
        isAvailable: false, delaySeconds: 0, rewindableSeconds: 0, isAtLiveEdge: true)
}
