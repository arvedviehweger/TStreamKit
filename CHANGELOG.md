# Changelog

All notable changes to TStreamKit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-08-14

### Fixed
- Anamorphic WebM played squeezed towards square, while the same channel over
  MPEG-TS filled the frame correctly. VP8 cannot signal an aspect ratio at all,
  so for WebM the container's display size is the only record of the picture's
  shape, and it was never read. The container's pixel aspect now reaches the
  decoder and is only consulted when the bitstream is silent, so H.264, HEVC and
  MPEG-2 keep signalling their own, as does MPEG-TS.

### Added
- x86_64 support, so the package builds and runs on Intel Macs. The FFmpeg
  frameworks now carry arm64 and x86_64 slices for macOS and for the iOS and
  tvOS simulators. Devices stay arm64 only. The x86 slices are built with full
  SIMD, so software decode keeps its speed.
- `dSYM`s for the FFmpeg frameworks, shipped inside the `xcframework`s. An app
  embedding TStreamKit no longer gets "no debug symbol file" warnings from App
  Store Connect, and FFmpeg frames in crash reports resolve to function and
  line. The shipped binaries are unchanged in size, the debug info lives in the
  `dSYM`s.

## [1.1.0] - 2026-08-14

### Added
- Matroska, WebM and fragmented MP4 playback alongside MPEG-TS, so a channel
  plays whichever streaming profile a transcoding server serves it under. The
  container is recognised from the stream itself rather than from
  `Content-Type`, which servers mislabel, and detection runs on the live
  connection so no second request is made.
- VP8 video, plus Vorbis and Opus audio decoded to PCM.
- AAC profiles Core Audio has no decoder for, AAC Main among them, are decoded
  by libavcodec instead of playing silently. Which path a stream takes is
  decided by asking Core Audio, not from a fixed list, so it follows what the
  running OS and device support.

### Fixed
- AAC could play as video with no sound at all. The magic cookie has to be an
  MPEG-4 elementary stream descriptor rather than the bare AudioSpecificConfig
  a container stores, and the kind of AAC has to be read from that config
  instead of assumed to be AAC-LC. Creating the format description reports no
  error either way, so this only surfaced as silence. The MPEG-TS path was
  affected as well, for AAC and for transcoded MP2.
- Decoded audio clicked at the frame rate. Container timestamps are rounded to
  milliseconds while an audio frame lasts a fraction of one, and a PCM buffer is
  placed at exactly the time it is given, so the rounding left a gap or an
  overlap at every buffer edge. Decoded audio now runs on a timeline set by the
  sample count.

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

[1.2.0]: https://github.com/arvedviehweger/TStreamKit/releases/tag/v1.2.0
[1.1.0]: https://github.com/arvedviehweger/TStreamKit/releases/tag/v1.1.0
[1.0.1]: https://github.com/arvedviehweger/TStreamKit/releases/tag/v1.0.1
[1.0.0]: https://github.com/arvedviehweger/TStreamKit/releases/tag/v1.0.0
