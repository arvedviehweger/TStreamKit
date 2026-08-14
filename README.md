# TStreamKit

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20tvOS%20%7C%20macOS-blue.svg)](#requirements)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](#installation)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![FFmpeg: LGPL v3](https://img.shields.io/badge/FFmpeg-LGPL%20v3-lightgrey.svg)](#lgpl-compliance)

A native Swift package for **iOS / tvOS / macOS** that plays live HTTP
**MPEG-TS** streams — the raw transport streams served by DVB/ATSC tuners and
gateways, SAT>IP servers, IPTV relays (`udpxy` & friends), capture boxes, and
tools like `ffmpeg`/`VLC` — directly on Apple devices, including the non-IDR,
interlaced, open-GOP broadcast streams that `AVPlayer` chokes on. If your source
can serve an MPEG-TS over HTTP(S), TStreamKit can play it.

Servers that transcode rather than pass the mux through are covered too:
**Matroska, WebM and fragmented MP4** are recognised from the stream itself, so
a channel plays whichever profile it is served under.

TStreamKit demuxes the transport stream itself and decodes video with a minimal,
self-built **FFmpeg `libavcodec`** (software decode with error concealment and
`bwdif` deinterlacing), rendering into an `AVSampleBufferDisplayLayer`. Audio
goes to the system renderer wherever Core Audio can decode it, and to
`libavcodec` where it cannot. The result is smooth, broadcast-rate playback of
German/European DVB and US ATSC channels that VideoToolbox-backed players can't
handle.

> **Licensing note:** TStreamKit links FFmpeg, which is **LGPL v3**. The
> TStreamKit source is MIT, but shipping an app that embeds it carries LGPL
> obligations. See [LGPL compliance](#lgpl-compliance).

## Contents

- [Pipeline](#pipeline)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [SwiftUI](#swiftui)
  - [View modifiers](#view-modifiers)
  - [Seeking & progress (recordings)](#seeking--progress-recordings)
  - [UIKit](#uikit)
  - [AppKit](#appkit)
  - [Diagnostics](#diagnostics)
  - [App Transport Security](#app-transport-security)
- [Container & codec support](#container--codec-support)
- [LGPL compliance](#lgpl-compliance)
- [License](#license)

## Pipeline

```
HTTP stream (DVB/ATSC gateway, SAT>IP, IPTV relay, transcoding server, …)
        │
        ▼
container recognised from the first bytes
        │
        ├─► MPEG-TS ──────────► TSPacketParser ──► TSDemuxer
        │                                          (PAT/PMT/PES, descriptors)
        └─► Matroska/WebM/MP4 ─► libavformat
                                      │
        ┌─────────────────────────────┴──────────────┐
   video packets                               audio packets
        ▼                                            ▼
libavcodec decode                    AVSampleBufferAudioRenderer
(concealment + bwdif)                (AAC / AC-3 / E-AC-3; MP2 → AAC)
        │                                            │
        │                              or libavcodec → PCM where
        │                              Core Audio has no decoder
        ▼                                            │
I420 CVPixelBuffer ──► AVSampleBufferDisplayLayer    │
        │                                            │
        └──────► AVSampleBufferRenderSynchronizer ◄───┘
                          (A/V sync)
```

Video is decoded in software on purpose: VideoToolbox cannot robustly recover
from the corrupt/non-IDR pictures and PAFF interlacing common in live DVB.
`libavcodec` conceals errors, deinterlaces (50p for SD, adaptive 25p for HD),
and outputs zero-copy I420 frames straight into the display layer.

## Requirements

- iOS 15+ / tvOS 15+ / macOS 12+
- Swift 6 toolchain (builds in language mode 5)
- Apple platforms only. The FFmpeg frameworks cover arm64 devices, and arm64 +
  x86_64 on macOS and the simulators, so Intel Macs are supported.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/arvedviehweger/TStreamKit.git", from: "1.0.0")
```

The package vendors prebuilt **dynamic** FFmpeg `xcframework`s under
`Frameworks/`, so it works directly in Xcode with no extra build step. Xcode
embeds and signs them automatically when you add the package to an app target.

## Usage

The whole public API is one SwiftUI view, `TStreamPlayerView`, plus a small
imperative `TStreamPlayerHandle` for seeking. Everything below builds on those
two types.

### SwiftUI

```swift
import SwiftUI
import TStreamKit

struct PlayerScreen: View {
    let url = URL(string: "http://192.168.1.10:8080/stream.ts")!

    var body: some View {
        TStreamPlayerView(url: url, headers: ["Authorization": "Basic …"])
            .onReadyToPlay { print("playing") }
            .onPlaybackError { error in print("TStreamKit error:", error) }
            .ignoresSafeArea()
    }
}
```

`TStreamPlayerView` starts playback on appear and tears the player down on
disappear. The view fills its container and renders into a black background, so
size it like any other view (`.frame`, `.aspectRatio(16/9, contentMode: .fit)`,
`.ignoresSafeArea()`, …).

Initializer parameters:

| Parameter  | Type                  | Default | Meaning                                              |
|------------|-----------------------|---------|------------------------------------------------------|
| `url`      | `URL`                 | —       | HTTP(S) MPEG-TS endpoint.                            |
| `headers`  | `[String: String]`    | `[:]`   | Extra HTTP request headers, e.g. `Authorization`.    |
| `autoPlay` | `Bool`                | `true`  | Start on appear. Pass `false` to defer playback.     |

> **Reloading a stream:** to switch URLs or restart, give the view a changing
> `.id(...)` so SwiftUI rebuilds it (the bundled demo uses a `reloadToken`).

### View modifiers

Each modifier returns a new `TStreamPlayerView`, so they chain. All callbacks
fire on the **main thread**.

| Modifier                       | Purpose                                                                 |
|--------------------------------|-------------------------------------------------------------------------|
| `.onReadyToPlay { }`           | Called once when the clock starts and the first frame is on screen.     |
| `.onPlaybackError { error }`   | Delivers a [`TStreamError`](Sources/TStreamKit/TStreamError.swift).     |
| `.onProgress { seconds }`      | Elapsed seconds since the first frame, ~4×/second while playing.        |
| `.paused(_ value: Bool)`       | Freeze (`true`) / resume (`false`) video **and** audio.                 |
| `.handle(_ handle:)`           | Attach a `TStreamPlayerHandle` for imperative seeking (see below).      |

```swift
struct PlayerScreen: View {
    let url: URL
    @State private var isPaused = false
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        VStack {
            TStreamPlayerView(url: url)
                .paused(isPaused)
                .onProgress { elapsed = $0 }
                .aspectRatio(16/9, contentMode: .fit)

            HStack {
                Button(isPaused ? "Resume" : "Pause") { isPaused.toggle() }
                Text(timecode(elapsed)).monospacedDigit()
            }
        }
    }
}
```

### Seeking & progress (recordings)

For **recordings** (a finite MPEG-TS file/endpoint with a known length) you can
scrub. Seeking is *approximate / GOP-accurate*: it jumps to `fraction × totalBytes`,
resyncs to the next TS packet, and resumes decoding at the next keyframe.
Create a `TStreamPlayerHandle`, attach it with `.handle(_:)`, and call
`seek(toFraction:)` (0…1) when the user scrubs.

```swift
struct RecordingPlayer: View {
    let url: URL
    @State private var handle = TStreamPlayerHandle()
    @State private var elapsed: TimeInterval = 0
    @State private var scrub: Double = 0

    var body: some View {
        VStack {
            TStreamPlayerView(url: url)
                .handle(handle)
                .onProgress { elapsed = $0 }
                .aspectRatio(16/9, contentMode: .fit)

            Slider(value: $scrub, in: 0...1) { editing in
                if !editing { handle.seek(toFraction: scrub) }  // seek on release
            }
        }
    }
}
```

> Live streams have no end, so `seek(toFraction:)` is a no-op until the source
> reports a total byte count. `onProgress` reports an **absolute** offset that
> stays correct across seeks.

### UIKit

There is no separate UIKit view — host `TStreamPlayerView` in a
`UIHostingController`. The minimal case is a one-liner:

```swift
let player = TStreamPlayerView(url: url).ignoresSafeArea()
let vc = UIHostingController(rootView: player)
present(vc, animated: true)
```

To embed it in your own view controller and wire up the callbacks, pause and
seeking, drive the hosting controller's `rootView` from state. A complete
controller:

```swift
import UIKit
import SwiftUI
import TStreamKit

final class StreamViewController: UIViewController {
    private let url: URL
    private let handle = TStreamPlayerHandle()
    private var isPaused = false { didSet { updatePlayer() } }

    private lazy var hosting = UIHostingController(rootView: makePlayer())
    private let statusLabel = UILabel()
    private let scrubber = UISlider()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("use init(url:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Embed the SwiftUI player as a child view controller.
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        // … add statusLabel, a play/pause button, and `scrubber`, then: …
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.heightAnchor.constraint(equalTo: hosting.view.widthAnchor,
                                                 multiplier: 9.0 / 16.0),
        ])
        scrubber.addTarget(self, action: #selector(scrubEnded), for: .touchUpInside)
    }

    @objc private func togglePause() { isPaused.toggle() }

    @objc private func scrubEnded() {
        handle.seek(toFraction: Double(scrubber.value))   // 0…1
    }

    private func updatePlayer() { hosting.rootView = makePlayer() }

    // Rebuild the SwiftUI view whenever state (e.g. pause) changes.
    private func makePlayer() -> TStreamPlayerView {
        TStreamPlayerView(url: url, headers: ["Authorization": "Basic …"])
            .paused(isPaused)
            .handle(handle)
            .onReadyToPlay { [weak self] in self?.statusLabel.text = "Playing" }
            .onProgress   { [weak self] s in self?.scrubber.value = Float(s) /* / duration */ }
            .onPlaybackError { [weak self] error in
                self?.statusLabel.text = error.localizedDescription
            }
    }
}
```

The `handle` is created once and survives `rootView` reassignment, so seeking
keeps working as you rebuild the view for pause/state changes.

### AppKit

Identical pattern with `NSHostingController`:

```swift
import AppKit
import SwiftUI
import TStreamKit

let hosting = NSHostingController(
    rootView: TStreamPlayerView(url: url)
        .handle(handle)
        .onPlaybackError { print($0.localizedDescription) }
)
// add hosting.view to your window/content view, or present it.
window.contentViewController = hosting
```

### Diagnostics

```swift
TStreamDiagnostics.isEnabled = true   // logs to os_log subsystem "com.tstream"
```

Per-frame decode/deinterlace timing is logged here (`ffdec: …`), useful for
profiling on device.

### App Transport Security

The stream source is typically plain HTTP, so add an ATS exception for your host
in `Info.plist` (or `NSAllowsArbitraryLoads` for testing):

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>your-stream-host.local</key>
    <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
  </dict>
</dict>
```

## Container & codec support

| Container | Recognised by |
|---|---|
| MPEG-TS | 0x47 sync bytes at 188-byte strides |
| Matroska, WebM | EBML magic |
| MP4 (**fragmented**) | `ftyp` / `styp` / `moov` / `moof` |

The container is read from the stream itself rather than from `Content-Type`,
because servers mislabel it. Detection runs on the live connection, so no second
request is made and no stray transcode session is left behind on the server. A
plain MP4 keeps its index at the end and cannot be played while it is still
being written, so a live stream has to be fragmented.

| | Supported | Signaling |
|---|---|---|
| **Video** | H.264 (AVC), H.265 (HEVC), MPEG-2 | PMT 0x1B / 0x24 / 0x02 |
| | VP8 | Matroska/WebM |
| **Audio** | AAC (ADTS **and** LATM/LOAS) | PMT 0x0F / 0x11 |
| | AC-3 (Dolby Digital) | ATSC 0x81 · DVB 0x06 + desc 0x6A |
| | E-AC-3 (Dolby Digital Plus) | ATSC 0x87 · DVB 0x06 + desc 0x7A |
| | MPEG-1/2 Layer II (MP2) → transcoded to AAC | PMT 0x03 / 0x04 |
| | Vorbis, Opus → decoded to PCM | Matroska/WebM |

- Both **ATSC** (US) and **DVB** (Europe) PMT signaling are recognized, including
  the DVB AC-3/E-AC-3 descriptors that don't use the ATSC stream types.
- When a channel offers several audio tracks, Dolby is preferred
  (E-AC-3 > AC-3 > AAC/MP2), so the surround track wins where present.
- Audio stays compressed all the way to the system renderer wherever Core Audio
  can decode it. It has no decoder for **AAC Main**, which a transcoding server
  can produce, so that arrives as PCM from `libavcodec` instead. Which path a
  stream takes is decided by asking Core Audio rather than from a fixed list,
  so it follows what the running OS and device actually support.
- Video is decoded in software; HEVC/UHD works but is the heaviest case.
- Anamorphic SD aspect ratios and PAFF interlacing are handled.

Seeking is supported for **recordings** (approximate, GOP-accurate — see
[Seeking & progress](#seeking--progress-recordings)); live streams have no end
to seek within.

**Not supported:** AC-4 (no decoder exists on Apple platforms or in FFmpeg),
VP9, AV1, DRM/encrypted streams, and subtitles/teletext. Frame-accurate
scrubbing is out of scope — this targets live and simple recording playback, not
a full VOD/DVR engine.

## LGPL compliance

TStreamKit's own code is MIT-licensed. It links six FFmpeg libraries —
`libavcodec`, `libavformat`, `libavutil`, `libswscale`, `libswresample`,
`libavfilter` — which are licensed under the **GNU LGPL v3**. To keep
distribution clean:

- **No GPL components.** FFmpeg is configured `--disable-gpl --enable-version3`,
  decode-only, no encoders/muxers/network. The exact configuration lives in
  [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh).
- **Built from source.** FFmpeg 7.1 is downloaded and compiled by that script —
  no opaque prebuilt binaries. Re-run it with `scripts/build-ffmpeg.sh all` to
  reproduce every `Frameworks/*.xcframework`. The x86_64 slices need `nasm`
  (`brew install nasm`) for the SIMD kernels.
- **Dynamic linking (LGPL v3 §4).** The FFmpeg libraries are shipped as
  **dynamic** frameworks, so an end user can replace them with a modified FFmpeg
  and relink — satisfying the LGPL's relinking requirement without you having to
  release your app's source.

When you ship an app embedding TStreamKit you must still, per the LGPL:

1. **Attribute FFmpeg** and state it is used under the LGPL v3 (e.g. an
   acknowledgements / licenses screen), and
2. **Make the FFmpeg license text and corresponding source available** to your
   users — see [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) and the
   verbatim texts in [`Licenses/`](Licenses).

This is not legal advice; review the LGPL v3 for your distribution.

## License

- TStreamKit source: **MIT** — see [LICENSE](LICENSE).
- FFmpeg: **LGPL v3** — see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
- Vendored kjmp2 MP2 decoder: **zlib** (permissive, App Store safe).
