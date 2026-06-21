# TStreamKit

Native Swift library for iOS / tvOS / macOS that plays raw HTTP **MPEG-TS**
streams (e.g. from [Tvheadend](https://tvheadend.org)) in `AVPlayer` —
**no third-party dependencies, no GPL/LGPL code.**

TStreamKit pulls the MPEG-TS stream over HTTP, demuxes it, remuxes it into
**fragmented MP4 (fMP4)** and exposes it as a live **HLS** stream from a tiny
**loopback HTTP server** (127.0.0.1, `Network.framework`, nothing exposed
off-device). AVPlayer then plays it as ordinary HLS.

```
Tvheadend HTTP MPEG-TS
        ↓
TStreamPipeline:  TSPacketParser → TSDemuxer (PAT/PMT/PES) → FMP4Muxer (init + media segments)
        ↓
HLSStore (live m3u8 + fMP4 segments)
        ↓
HLSLocalServer  (http://127.0.0.1:<port>/index.m3u8)
        ↓
AVPlayer
```

> **Why a loopback server?** The original plan was to feed fMP4 straight into
> AVPlayer via `AVAssetResourceLoader`. That works for VOD but **not for live on
> iOS**: AVPlayer only parses a resource-loader request after it *finishes*
> (which never happens for a live stream), and HLS media segments served via a
> custom scheme must be redirected to real HTTP anyway. A minimal loopback HTTP
> server is the standard, robust way to deliver live HLS to AVPlayer. It uses no
> third-party code and binds to localhost only.

## Requirements

- iOS 15+ / tvOS 15+ / macOS 12+
- Swift 6 toolchain (package builds in language mode 5 — see `Package.swift`)
- Dependencies: none beyond `AVFoundation` and `Foundation`

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/arvedviehweger/TStreamKit.git", from: "1.0.0")
```

## Usage

### SwiftUI

```swift
import TStreamKit

struct PlayerScreen: View {
    var body: some View {
        TStreamPlayerView(url: URL(string: "http://tvheadend:9981/stream/channelid/123")!)
            .onPlaybackError { error in print("TStreamKit error:", error) }
    }
}
```

### UIKit / AppKit

```swift
import TStreamKit

let player = try TStreamPlayer(url: URL(string: "http://tvheadend:9981/stream/channelid/123")!)
player.onError = { print($0) }
player.play()
// ...
player.pause()
player.stop()
```

Attach `player.player` (the underlying `AVPlayer`) to an `AVPlayerLayer` or
`AVPlayerViewController` to render video.

### App Transport Security

The stream source and the loopback server are plain HTTP, so add to your
app's `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>   <!-- the 127.0.0.1 HLS server -->
    <true/>
    <!-- plus an exception for your (non-TLS) Tvheadend host, or NSAllowsArbitraryLoads for testing -->
</dict>
```

Loopback (127.0.0.1) connections do **not** trigger the iOS Local Network
permission prompt.

## Codec support (v1.0)

| | Supported | Notes |
|---|---|---|
| Video | **H.264** | H.265/HEVC is detected and reported as unsupported |
| Audio | **AAC** (ADTS) | AC-3 is detected and reported as unsupported |

Out of scope for v1.0: AES-128 encrypted streams, multi-language audio,
subtitles/teletext, timeshift/recording, UDP/RTP multicast.

## Architecture

| Module | Responsibility |
|---|---|
| `TStreamPlayer` / `TStreamPlayerView` | Public API; owns the pipeline, server and `AVPlayer` lifecycle |
| `TStreamPipeline` | HTTP fetch + parser → demuxer → muxer, fills the `HLSStore` |
| `HLSStore` | Thread-safe init segment + sliding window of segments; renders master/media playlists |
| `HLSLocalServer` | Loopback HTTP/1.1 server (`NWListener`) serving the playlists + segments |
| `TSPacketParser` | 188-byte packet framing, sync, resync |
| `TSDemuxer` | PAT/PMT resolution, PES reassembly, PTS/DTS, AVCC/AAC extraction |
| `FMP4Muxer` / `MP4Box` | ISO BMFF box writer; init segment + per-GOP HLS media segments (styp + sidx + moof + mdat) |
| `TStreamError` | Typed error surface |

## Status & validation

The component pipeline (packet parsing, PAT/PMT/PES demux, NAL/AVCC
conversion, ADTS framing, fMP4 box structure) plus full-path HLS playback are
covered by `swift test` (17 tests, incl. a real `AVPlayer` consuming the local
HLS server). Startup latency is roughly the buffer-ahead count (3 segments)
times the source GOP length; A/V are muxed into the same segments.

Remaining nice-to-haves: tune segment/window sizing for lower latency, optional
H.265/AC-3, and validation on a physical device.

## License

MIT — see [LICENSE](LICENSE). No GPL/LGPL dependencies; unrestricted App Store
and commercial use.
