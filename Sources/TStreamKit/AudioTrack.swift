import Foundation

/// One selectable sound track of a stream.
///
/// German and other European broadcasts routinely carry several: the original
/// language beside the dub, a Dolby track beside stereo, and the accessibility
/// tracks — audio description for blind viewers, a cleaner mix for hard-of-
/// hearing ones. Which one the demuxer picked by itself is rarely wrong, but it
/// is never the only reasonable answer.
public struct TStreamAudioTrack: Identifiable, Hashable, Sendable {
    /// Stable within one stream: the elementary PID for MPEG-TS, the stream
    /// index for a container.
    public let id: Int
    /// As the broadcast declares it — ISO 639-2, so "deu" rather than "de".
    /// Nil when the stream carries no language descriptor at all.
    public let language: String?
    /// For display beside the language: "Dolby Digital", "Stereo", …
    public let codecName: String
    public let kind: Kind

    /// What the broadcaster says the track is *for*, from the audio type in the
    /// ISO 639 language descriptor. Worth showing: picking "audio description"
    /// by accident is a confusing experience to recover from.
    public enum Kind: String, Hashable, Sendable {
        case normal
        case cleanEffects
        case hearingImpaired
        case audioDescription
    }

    public init(id: Int, language: String?, codecName: String, kind: Kind = .normal) {
        self.id = id
        self.language = language
        self.codecName = codecName
        self.kind = kind
    }
}
