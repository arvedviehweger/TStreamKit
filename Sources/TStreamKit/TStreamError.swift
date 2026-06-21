import Foundation

/// Errors surfaced by the TStream pipeline.
public enum TStreamError: Error, Equatable, Sendable {
    /// The provided URL could not be used to build a `tstream://` asset URL.
    case invalidURL(String)
    /// The HTTP transport failed (connection, status code, etc.).
    case transport(String)
    /// A transport-stream packet was malformed beyond recovery.
    case packet(String)
    /// The PAT/PMT could not be parsed or referenced an unsupported layout.
    case demux(String)
    /// A codec was found in the stream that this version does not support.
    case unsupportedCodec(String)
    /// fMP4 boxes could not be assembled.
    case mux(String)
    /// AVPlayer reported a failure while consuming the synthesized asset.
    case player(String)
}

extension TStreamError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let m):       return "Invalid URL: \(m)"
        case .transport(let m):        return "Transport error: \(m)"
        case .packet(let m):           return "TS packet error: \(m)"
        case .demux(let m):            return "Demux error: \(m)"
        case .unsupportedCodec(let m): return "Unsupported codec: \(m)"
        case .mux(let m):              return "Mux error: \(m)"
        case .player(let m):           return "Player error: \(m)"
        }
    }
}
