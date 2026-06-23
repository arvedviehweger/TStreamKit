# Third-party licenses

TStreamKit's own source is MIT-licensed (see `LICENSE`). It distributes and
links the following third-party components.

## FFmpeg — LGPL v3

`libavcodec`, `libavutil`, `libswscale`, and `libavfilter` from
[FFmpeg](https://ffmpeg.org) **7.1** are used for video decoding, pixel-format
conversion, and deinterlacing. They are licensed under the **GNU Lesser General
Public License, version 3** (full text: [`Licenses/LGPL-3.0.txt`](Licenses/LGPL-3.0.txt),
which incorporates [`Licenses/GPL-3.0.txt`](Licenses/GPL-3.0.txt)).

**Build configuration.** FFmpeg is compiled from unmodified upstream source by
[`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh) with
`--disable-gpl --enable-version3`, decode-only, and with all encoders, muxers,
demuxers, protocols, and network features disabled. **No GPL-licensed
components are enabled.** Only the H.264, HEVC, and MPEG-2 video decoders, the
matching parsers, `swscale`, and the `bwdif`/`yadif` deinterlace filters are
built.

**Modifications.** The FFmpeg source is used unmodified; only the build/packaging
is custom (a thin C shim, `Sources/CFFVideoDecoder`, calls the public API). The
libraries are shipped as **dynamic** frameworks under `Frameworks/`, so they can
be replaced and relinked as required by LGPL v3 §4.

**Corresponding source.** The exact FFmpeg version and configuration needed to
rebuild the binaries are defined in `scripts/build-ffmpeg.sh`; running
`scripts/build-ffmpeg.sh all` reproduces every `Frameworks/*.xcframework` from a
fresh upstream download.

### Your obligations when shipping an app

If you distribute an application that embeds TStreamKit (and thus FFmpeg), the
LGPL v3 requires that you:

1. **Attribute FFmpeg** and state that it is licensed under the LGPL v3 — for
   example on a "Licenses" / "Acknowledgements" screen.
2. **Provide the LGPL v3 license text** to your users (ship the files in
   `Licenses/`, or reproduce their contents).
3. **Allow relinking.** Because FFmpeg is dynamically linked here, this is
   satisfied as long as you keep it as a separate, replaceable framework (do not
   re-link it statically into your app binary) and make the corresponding FFmpeg
   source available (e.g. a link to the upstream release plus this build script).

This summary is informational, not legal advice. Consult the full LGPL v3 text
for the authoritative terms.

## kjmp2 — zlib license

`Sources/CKJMP2` vendors Martin Fiedler's **kjmp2** MPEG-1/2 Audio Layer II
decoder, used to transcode MP2 broadcast audio to AAC. kjmp2 is released under
the **zlib license** (permissive, commercial- and App-Store-safe); the license
header is retained in the source files.
