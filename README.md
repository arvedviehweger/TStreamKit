# TStreamKit

A native Swift package for **iOS / tvOS / macOS** that plays live HTTP
**MPEG-TS** streams — the kind served by DVB tuners and gateways such as
[Tvheadend](https://tvheadend.org) — directly on Apple devices, including the
non-IDR, interlaced, open-GOP broadcast streams that `AVPlayer` chokes on.

TStreamKit demuxes the transport stream itself and decodes video with a minimal,
self-built **FFmpeg `libavcodec`** (software decode with error concealment and
`bwdif` deinterlacing), rendering into an `AVSampleBufferDisplayLayer`. Audio is
decoded by the system renderer. The result is smooth, broadcast-rate playback of
German/European DVB and US ATSC channels that VideoToolbox-backed players can't
handle.

> **Licensing note:** TStreamKit links FFmpeg, which is **LGPL v3**. The
> TStreamKit source is MIT, but shipping an app that embeds it carries LGPL
> obligations. See [LGPL compliance](#lgpl-compliance).

## Pipeline

```
HTTP MPEG-TS (Tvheadend, DVB gateway, …)
        │
        ▼
TSPacketParser ──► TSDemuxer (PAT/PMT/PES, codec + descriptor detection)
        │                       │
   raw video PES            audio access units
        ▼                       ▼
libavcodec decode          AVSampleBufferAudioRenderer
(concealment + bwdif)      (AAC / AC-3 / E-AC-3; MP2 → AAC)
        ▼
I420 CVPixelBuffer ──► AVSampleBufferDisplayLayer
        │
        └──────► AVSampleBufferRenderSynchronizer (A/V sync)
```

Video is decoded in software on purpose: VideoToolbox cannot robustly recover
from the corrupt/non-IDR pictures and PAFF interlacing common in live DVB.
`libavcodec` conceals errors, deinterlaces (50p for SD, adaptive 25p for HD),
and outputs zero-copy I420 frames straight into the display layer.

## Requirements

- iOS 15+ / tvOS 15+ / macOS 12+
- Swift 6 toolchain (builds in language mode 5)
- Apple platforms only (the FFmpeg frameworks are arm64)

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/arvedviehweger/TStreamKit.git", from: "1.0.0")
```

The package vendors prebuilt **dynamic** FFmpeg `xcframework`s under
`Frameworks/`, so it works directly in Xcode with no extra build step. Xcode
embeds and signs them automatically when you add the package to an app target.

## Usage

The public API is a single SwiftUI view.

```swift
import SwiftUI
import TStreamKit

struct PlayerScreen: View {
    let url = URL(string: "http://tvheadend.local:9981/stream/channelid/123")!

    var body: some View {
        TStreamPlayerView(url: url, headers: ["Authorization": "Basic …"])
            .onReadyToPlay { print("playing") }
            .onPlaybackError { error in print("TStreamKit error:", error) }
            .ignoresSafeArea()
    }
}
```

`TStreamPlayerView` starts playback on appear and tears the player down on
disappear. `headers` are sent with the HTTP request (e.g. for Basic auth);
`autoPlay: false` defers playback.

### UIKit / AppKit

Host the SwiftUI view in a `UIHostingController` (or `NSHostingController`):

```swift
let vc = UIHostingController(
    rootView: TStreamPlayerView(url: url).ignoresSafeArea())
present(vc, animated: true)
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
    <key>tvheadend.local</key>
    <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
  </dict>
</dict>
```

## Codec support

| | Supported | Signaling |
|---|---|---|
| **Video** | H.264 (AVC), H.265 (HEVC), MPEG-2 | PMT 0x1B / 0x24 / 0x02 |
| **Audio** | AAC (ADTS **and** LATM/LOAS) | PMT 0x0F / 0x11 |
| | AC-3 (Dolby Digital) | ATSC 0x81 · DVB 0x06 + desc 0x6A |
| | E-AC-3 (Dolby Digital Plus) | ATSC 0x87 · DVB 0x06 + desc 0x7A |
| | MPEG-1/2 Layer II (MP2) → transcoded to AAC | PMT 0x03 / 0x04 |

- Both **ATSC** (US) and **DVB** (Europe) PMT signaling are recognized, including
  the DVB AC-3/E-AC-3 descriptors that don't use the ATSC stream types.
- When a channel offers several audio tracks, Dolby is preferred
  (E-AC-3 > AC-3 > AAC/MP2), so the surround track wins where present.
- Video is decoded in software; HEVC/UHD works but is the heaviest case.
- Anamorphic SD aspect ratios and PAFF interlacing are handled.

**Not supported:** AC-4 (no decoder exists on Apple platforms or in FFmpeg),
DRM/encrypted streams, subtitles/teletext, and seeking/scrubbing — this is a
live player, not a VOD/DVR engine.

## LGPL compliance

TStreamKit's own code is MIT-licensed. It links four FFmpeg libraries —
`libavcodec`, `libavutil`, `libswscale`, `libavfilter` — which are licensed
under the **GNU LGPL v3**. To keep distribution clean:

- **No GPL components.** FFmpeg is configured `--disable-gpl --enable-version3`,
  decode-only, no encoders/muxers/network. The exact configuration lives in
  [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh).
- **Built from source.** FFmpeg 7.1 is downloaded and compiled by that script —
  no opaque prebuilt binaries. Re-run it with `scripts/build-ffmpeg.sh all` to
  reproduce every `Frameworks/*.xcframework`.
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
