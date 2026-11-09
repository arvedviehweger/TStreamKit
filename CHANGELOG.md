# Changelog

All notable changes to TStreamKit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- A black Picture in Picture window appeared on backgrounding after the player
  had been closed. Three things kept it coming: the player handle held the
  controller strongly and outlived the teardown, so a controller still armed
  for automatic start survived the layer it drew from; stopping the window did
  not disarm that automatic start or release the content source; and the
  automatic start was armed before anything was known about the stream, so a
  radio channel — or one that never produced a frame — floated an empty window
  too. The handle's reference is now weak, teardown invalidates the controller
  outright, and the automatic start is only armed once a first frame has
  played and the stream is known to carry video.

### Added
- Sound-track selection. The MPEG-TS demuxer now reports every audio stream the
  programme map lists rather than only the one it picked, with the language and
  audio type from the ISO 639 descriptor — so audio description and
  hard-of-hearing mixes can be labelled as such instead of appearing as a
  second anonymous "German". `onAudioTracks` reports the menu,
  `selectAudioTrack(id:)` switches, and the automatic pick (Dolby over stereo)
  is unchanged as the starting point. Switching flushes the audio renderer and
  waits for the new format; the picture never stops, because the clock runs off
  the video throughout. Containers demuxed by libavformat report no tracks,
  which reads as "nothing to choose".
- Background audio: `videoSuspended(_:)` turns the picture off while the sound
  keeps playing, for a host that holds the `audio` background mode. The display
  layer stops asking for frames once the screen is off, which used to stall the
  pipeline, back the source up and cut the audio with it; video is now dropped
  at ingest instead and the audio timeline takes over the clock and the
  backpressure measurement — the same path a radio channel already used.
- Picture in Picture, through `AVPictureInPictureController`'s sample-buffer
  content source, so the existing display layer becomes the window's content
  without an `AVPlayer` anywhere. `pictureInPicture(_:automatically:)` enables
  it, the handle starts and stops it, `onPictureInPictureChange` reports the
  window, and `onSkipRequest` hands its skip buttons to the host — only the
  host knows whether to rewind a live stream or seek in a recording. Video is
  never suspended while the window is up.


### Added
- Pausing and rewinding **live** streams. With a `TStreamTimeshiftConfiguration`
  attached, compressed access units are recorded to a ring on disk while they
  play, so a pause keeps recording and resuming continues from the frozen frame
  instead of jumping forward. `TStreamPlayerHandle.skipTimeshift(by:)` rewinds
  into what has already aired and `returnToLive()` rejoins the broadcast;
  replay is paced at real time and catches back up on its own.
  `.onTimeshiftStatus` reports how far behind live playback is and how much
  further back it can go. The ring holds compressed units rather than decoded
  frames, so an hour of HD costs about a gigabyte of disk and almost no memory
  — and if it can't be created, or a write fails, the stream keeps playing
  without it.
- Playback of local files: a `file:` URL is read off disk instead of over HTTP,
  through the same container detection and demuxers. A file always has a length,
  so a downloaded recording scrubs like a streamed one.

### Fixed
- Recordings no longer get the app killed for memory a few seconds in on a
  fast link (an Apple TV on gigabit Ethernet) or from a local file. The buffer
  ahead of playback is now held compressed and decoded only 1.5 s ahead of the
  clock; before, everything already fetched when the source was throttled was
  still decoded into full-size frames. A 1080i recording played from disk
  peaks at roughly half the memory it did.
- A recording no longer stops with "The request timed out" after a long pause.
  A suspended request keeps running its timeout, so a pause longer than 20 s —
  the viewer's own, or the source held back while the buffer drains — killed
  the connection. A recording whose connection breaks off mid-file now
  continues from the next byte with a `Range` request (after `resume()` if it
  is paused), and gives up only after three reconnects that bring no data or
  when the server answers without honouring the range.
- AAC the system decoder refuses is now decoded here on the **MPEG-TS** path as
  well, not only in the containers libavformat reads. A transcoding server that
  labels its output AAC Main — tvheadend's `webtv-h264-aac-mpegts` profile does
  — played its video in silence.

### Changed
- Demuxers now report whether a video packet is a random-access point. The
  decode path ignores it — libavcodec finds its own restart point — but a
  rewind can only resume from one.

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
