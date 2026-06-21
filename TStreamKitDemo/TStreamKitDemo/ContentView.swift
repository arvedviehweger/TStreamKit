import SwiftUI
import TStreamKit

struct ContentView: View {
    private static let defaultURL = "http://127.0.0.1:8080/stream.ts"

    @State private var urlText = ContentView.defaultURL
    @State private var activeURL: URL?
    @State private var status = "Idle"
    @State private var lastError: String?
    @State private var reloadToken = 0

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

            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        activeURL = url
        reloadToken += 1
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
