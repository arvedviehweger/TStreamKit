import Foundation

/// The container a stream arrives in. tvheadend can hand out any of its
/// streaming profiles for the same channel (`pass` gives MPEG-TS, the `webtv-*`
/// profiles give Matroska, WebM or MP4), and the client can't know in advance
/// which one the server is configured for, so we detect it from the bytes.
enum ContainerFormat: Equatable {
    case mpegTS
    /// Matroska and WebM are the same container; only the codecs differ.
    case matroska
    /// ISO base media, including the fragmented form used for live streaming.
    case mp4
}

extension ContainerFormat {
    /// How many bytes to buffer before giving up on detection. Matroska and MP4
    /// are decided within a dozen bytes; MPEG-TS needs a few 188-byte strides,
    /// and may need a little slack if the stream doesn't start packet-aligned.
    static let probeLimit = 4096

    /// Identifies the container from the head of a stream. Returns nil while the
    /// bytes so far are inconclusive: feed more and ask again, and treat
    /// `probeLimit` bytes without an answer as an unknown container.
    ///
    /// Magic bytes are checked before any `Content-Type`, because servers and
    /// proxies mislabel streams often enough that the header can't be trusted.
    static func detect<C: Collection>(_ bytes: C) -> ContainerFormat? where C.Element == UInt8 {
        let b = Array(bytes)

        // EBML header: Matroska and WebM both start with it.
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 {
            return .matroska
        }

        // ISO base media: a box whose type is ftyp (plain) or styp (a fragmented
        // segment). Some fragmented streams lead with moov/moof instead.
        if b.count >= 8 {
            let boxType = String(bytes: b[4..<8], encoding: .ascii)
            if boxType == "ftyp" || boxType == "styp" || boxType == "moov" || boxType == "moof" {
                return .mp4
            }
        }

        if hasTransportStreamSyncPattern(b) { return .mpegTS }

        return nil
    }

    /// MPEG-TS has no magic number, just a 0x47 sync byte every 188 bytes. We
    /// require three in a row so a stray 0x47 inside another container's payload
    /// can't be mistaken for one, and we scan forward because a live stream can
    /// start mid-packet.
    private static func hasTransportStreamSyncPattern(_ b: [UInt8]) -> Bool {
        let packet = TSPacketParser.packetSize
        let strides = 2                       // sync at i, i+188, i+376
        let needed = packet * strides + 1
        guard b.count >= needed else { return false }

        for i in 0...(b.count - needed) {
            guard b[i] == TSPacketParser.syncByte else { continue }
            if (1...strides).allSatisfy({ b[i + $0 * packet] == TSPacketParser.syncByte }) {
                return true
            }
        }
        return false
    }
}
