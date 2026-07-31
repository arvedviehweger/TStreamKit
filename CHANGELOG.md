# Changelog

All notable changes to TStreamKit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-07-19

### Fixed
- Intermittent audio dropouts during long HD playback. Audio refill and video
  decode shared one serial queue, so a slow libavcodec decode (worse under
  thermal throttling) could starve the audio renderer. Audio now drains on a
  dedicated queue, fully decoupled from video decode.

## [1.0.0]

Initial release.

- Self-contained MPEG-TS demuxer (PAT/PMT/PES) with ATSC **and** DVB signaling.
- libavcodec video decode (H.264, HEVC, MPEG-2) with error concealment and
  `bwdif` deinterlacing, zero-copy I420 into `AVSampleBufferDisplayLayer`.
- Audio: AAC (ADTS + LATM/LOAS), AC-3, E-AC-3, and MP2 → AAC.
- SwiftUI `TStreamPlayerView` (plus UIKit/AppKit hosting) with pause/resume,
  progress reporting, and approximate seeking for recordings.

[1.0.1]: https://github.com/arvedviehweger/TStreamKit/releases/tag/v1.0.1
[1.0.0]: https://github.com/arvedviehweger/TStreamKit/releases/tag/v1.0.0
