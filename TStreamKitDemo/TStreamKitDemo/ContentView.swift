import SwiftUI
import TStreamKit

struct ContentView: View {
    private static let defaultURL = "http://127.0.0.1:8080/stream.ts"

    @State private var urlText = ContentView.defaultURL
    @State private var activeURL: URL?
    @State private var status = "Idle"
    @State private var lastError: String?
    @State private var reloadToken = 0

    // Playback state driven into the player view.
    @State private var isPaused = false
    @State private var elapsed: TimeInterval = 0
    @State private var scrub: Double = 0
    @State private var isScrubbing = false

    // Imperative handle for seeking (works for finite recordings).
    @State private var handle = TStreamPlayerHandle()

    var body: some View {
        VStack(spacing: 0) {
            playerArea
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)

            controls
                .padding()
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            if let activeURL {
                TStreamPlayerView(url: activeURL)
                    .paused(isPaused)
                    .handle(handle)
                    .onProgress { seconds in
                        elapsed = seconds
                        // Don't fight the user while they drag the scrubber.
                        if !isScrubbing { scrub = seconds }
                    }
                    .onPlaybackError { error in
                        lastError = error.localizedDescription
                        status = "Error"
                    }
                    .onReadyToPlay {
                        status = "Playing"
                    }
                    .id(reloadToken) // rebuild the player on reload
            } else {
                Text("No stream loaded")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TStreamKit Demo")
                .font(.title2.bold())

            TextField("Stream URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.callout, design: .monospaced))

            HStack {
                Button(action: load) {
                    Label("Load / Reload", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Label(status, systemImage: statusIcon)
                    .font(.subheadline)
                    .foregroundColor(statusColor)
            }

            if activeURL != nil {
                transportControls
            }

            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Pause/resume, elapsed timecode, and a scrubber. Seeking is approximate and
    // only does something for finite recordings (a live stream has no length).
    private var transportControls: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    isPaused.toggle()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 28)
                }
                .buttonStyle(.bordered)

                Text(timecode(elapsed))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Text("seek")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Slider value is a 0…1 fraction of the recording. We seek on release
            // so we don't thrash the source while dragging.
            Slider(
                value: $scrub,
                in: 0...max(elapsed, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing, elapsed > 0 {
                        handle.seek(toFraction: scrub / max(elapsed, 1))
                    }
                }
            )
            .disabled(activeURL == nil)
        }
    }

    private func load() {
        lastError = nil
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            status = "Invalid URL"
            lastError = "Enter a valid http(s):// MPEG-TS URL."
            activeURL = nil
            return
        }
        status = "Loading"
        isPaused = false
        elapsed = 0
        scrub = 0
        activeURL = url
        reloadToken += 1
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private var statusIcon: String {
        switch status {
        case "Loading": return "arrow.triangle.2.circlepath"
        case "Playing": return "play.fill"
        case "Error", "Invalid URL": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case "Error", "Invalid URL": return .red
        case "Loading": return .orange
        case "Playing": return .green
        default: return .secondary
        }
    }
}

#Preview {
    ContentView()
}
