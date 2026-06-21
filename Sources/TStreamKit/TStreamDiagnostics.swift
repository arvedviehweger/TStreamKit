import Foundation
import os

/// Lightweight diagnostics for tracing the pipeline during bring-up.
///
/// Disabled by default. Enable from app code with
/// `TStreamDiagnostics.isEnabled = true`; output goes to the unified log under
/// subsystem `com.tstream` (visible via `log show --predicate
/// 'subsystem == "com.tstream"'` or Console.app).
public enum TStreamDiagnostics {
    /// Toggles all TStream logging. Off by default to stay silent in production.
    public nonisolated(unsafe) static var isEnabled = false

    private static let logger = Logger(subsystem: "com.tstream", category: "pipeline")

    /// When true, also writes to stdout (handy in `swift test`, where os_log
    /// does not reach the console). Defaults to false.
    public nonisolated(unsafe) static var mirrorsToStandardOut = false

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
        if mirrorsToStandardOut { print("[tstream] \(text)") }
    }
}
