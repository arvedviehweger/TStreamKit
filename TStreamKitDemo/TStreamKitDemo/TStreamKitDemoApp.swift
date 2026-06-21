import SwiftUI
import TStreamKit

@main
struct TStreamKitDemoApp: App {
    init() {
        // Pipeline logging to the unified log (subsystem com.tstream).
        TStreamDiagnostics.isEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
