#!/usr/bin/env bash
#
# Builds a minimal, LGPL-only FFmpeg for Apple platforms and packages it as
# xcframeworks. Decode only: no GPL components, no network, no muxers/encoders.
#
# TStreamKit demuxes MPEG-TS itself, so libavformat is here purely for the
# containers a transcoding server can serve instead (Matroska/WebM and MP4).
# Audio goes to the system decoder wherever Core Audio can handle it, so
# libavcodec only carries the codecs it cannot.
#
# Usage:
#   scripts/build-ffmpeg.sh macos          # one platform (smoke test)
#   scripts/build-ffmpeg.sh all            # every Apple platform + xcframeworks
#
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.ffmpeg-build"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
OUT="$WORK/install"
LIBS=(libavcodec libavutil libswscale libavfilter libavformat libswresample)

# --- minimal LGPL feature set ------------------------------------------------
# Every disable comes first, then the enables. configure applies these in order,
# so a blanket --disable-demuxers listed after --enable-demuxer would silently
# undo it.
CONFIGURE_COMMON=(
  --disable-gpl --enable-version3            # LGPL v3, no GPL components
  # Hermetic build: never auto-detect/link host libraries. Without this the
  # macOS build picks up Homebrew's libX11 (/opt/homebrew/.../libX11.6.dylib)
  # and links it into every lib, which then fails to load in a signed app
  # (different Team ID) and crashes at launch. We use none of those external
  # libs (software decode + bwdif/yadif only).
  --disable-autodetect
  --disable-everything
  --disable-avdevice --disable-postproc
  --disable-programs --disable-doc --disable-htmlpages --disable-manpages
  # No protocols: libavformat reads through an AVIOContext we supply, which is
  # backed by the same URLSession download the TS path uses.
  --disable-network --disable-protocols
  --disable-encoders --disable-muxers --disable-demuxers --disable-bsfs

  --enable-avcodec --enable-avutil --enable-swscale --enable-avfilter
  --enable-avformat --enable-swresample

  # Containers. MPEG-TS is handled by our own demuxer, which is tuned for DVB
  # broadcast, so libavformat only covers what we cannot already read.
  # matroska also reads WebM; mov also reads MP4 and its fragmented form.
  --enable-demuxer=matroska,mov

  # Decoders. vp8, vorbis and opus are the webtv-* profile codecs; the rest is
  # broadcast video. AC-3, E-AC-3 and MP2 are absent on purpose: those go to
  # the system decoder. AAC is here as a fallback only, for the profiles Core
  # Audio refuses, such as AAC Main.
  --enable-decoder=h264,hevc,mpeg2video,mpeg4,vp8,vorbis,opus,aac
  --enable-parser=h264,hevc,mpegvideo,mpeg4video   # mpegvideo = MPEG-1/2 (no "mpeg2video" parser exists)
  --enable-filter=bwdif,yadif,buffer,buffersink   # deinterlacing

  # Dynamic frameworks (LGPLv3 §4: the user can relink against a modified
  # FFmpeg). install-name-dir=@rpath lets us repackage the dylibs as embedded
  # .frameworks. See README "LGPL compliance".
  --enable-pic --enable-shared --disable-static --disable-debug
  --install-name-dir=@rpath
)

download() {
  mkdir -p "$WORK"
  if [ ! -d "$SRC" ]; then
    echo "==> downloading FFmpeg $FFMPEG_VERSION"
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$WORK/ffmpeg.tar.xz"
    tar -xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
  fi
}

# build_one <name> <arch> <sdk> <min-flag>
build_one() {
  local name="$1" arch="$2" sdk="$3" minflag="$4"
  local prefix="$OUT/$name-$arch"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local cc; cc="$(xcrun --sdk "$sdk" --find clang)"
  echo "==> building $name/$arch (sdk=$sdk)"

  local build="$WORK/build/$name-$arch"
  rm -rf "$build"; mkdir -p "$build"
  ( cd "$build"
    "$SRC/configure" \
      --prefix="$prefix" \
      --enable-cross-compile \
      --target-os=darwin \
      --arch="$arch" \
      --cc="$cc" \
      --sysroot="$sysroot" \
      --extra-cflags="-arch $arch -isysroot $sysroot $minflag" \
      --extra-ldflags="-arch $arch -isysroot $sysroot $minflag" \
      "${CONFIGURE_COMMON[@]}"
    make -j"$(sysctl -n hw.ncpu)"
    make install
  )
}

# Wraps a built dylib in a .framework, fixing its install name and the
# references to its sibling FFmpeg dylibs so they resolve as embedded frameworks
# (@rpath/<lib>.framework/<lib>). macOS frameworks are versioned, iOS/tvOS flat.
# <variant> <lib> <platform-id> <min-os> <is-macos:0|1>
build_framework() {
  local name="$1" lib="$2" platform="$3" minos="$4" macos="$5"
  local libdir="$OUT/$name-arm64/lib"
  local src; src="$(ls "$libdir/$lib".*.dylib 2>/dev/null | head -1 || true)"
  [ -n "$src" ] || src="$libdir/$lib.dylib"

  local fw="$OUT/fw-$name/$lib.framework"
  rm -rf "$fw"; mkdir -p "$fw"
  local bin plistdir
  if [ "$macos" = "1" ]; then
    mkdir -p "$fw/Versions/A/Resources"
    cp "$src" "$fw/Versions/A/$lib"
    ( cd "$fw"; ln -s A Versions/Current; ln -s Versions/Current/"$lib" "$lib"; ln -s Versions/Current/Resources Resources )
    bin="$fw/Versions/A/$lib"; plistdir="$fw/Versions/A/Resources"
  else
    cp "$src" "$fw/$lib"
    bin="$fw/$lib"; plistdir="$fw"
  fi

  chmod u+w "$bin"
  install_name_tool -id "@rpath/$lib.framework/$lib" "$bin"
  for dep in "${LIBS[@]}"; do
    if [ "$dep" != "$lib" ]; then
      local ref; ref="$(otool -L "$bin" | awk '{print $1}' | grep -E "/$dep\.[0-9]+\.dylib$" | head -1 || true)"
      if [ -n "$ref" ]; then
        install_name_tool -change "$ref" "@rpath/$dep.framework/$dep" "$bin"
      fi
    fi
  done

  cat > "$plistdir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$lib</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.$lib</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$lib</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$FFMPEG_VERSION</string>
  <key>CFBundleVersion</key><string>$FFMPEG_VERSION</string>
  <key>MinimumOSVersion</key><string>$minos</string>
</dict></plist>
PLIST
}

# Assemble one xcframework for <lib> across all platform variants.
make_xcframework() {
  local lib="$1"
  build_framework macos    "$lib" macos          12.0 1
  build_framework ios      "$lib" iphoneos        15.0 0
  build_framework iossim   "$lib" iphonesimulator 15.0 0
  build_framework tvos     "$lib" appletvos       15.0 0
  build_framework tvossim  "$lib" appletvsimulator 15.0 0
  rm -rf "$ROOT/Frameworks/$lib.xcframework"
  mkdir -p "$ROOT/Frameworks"
  xcodebuild -create-xcframework \
    -framework "$OUT/fw-macos/$lib.framework" \
    -framework "$OUT/fw-ios/$lib.framework" \
    -framework "$OUT/fw-iossim/$lib.framework" \
    -framework "$OUT/fw-tvos/$lib.framework" \
    -framework "$OUT/fw-tvossim/$lib.framework" \
    -output "$ROOT/Frameworks/$lib.xcframework"
}

case "${1:-macos}" in
  macos)
    download
    build_one macos arm64 macosx "-mmacosx-version-min=12.0"
    echo "==> macOS smoke build done: $OUT/macos-arm64/lib"
    ls -la "$OUT/macos-arm64/lib"/*.a
    ;;
  all)
    download
    # arm64 only (Apple Silicon Macs + their simulators + devices). x86_64
    # simulator slices would need nasm and only matter on Intel Macs.
    build_one macos       arm64  macosx            "-mmacosx-version-min=12.0"
    build_one ios         arm64  iphoneos          "-miphoneos-version-min=15.0"
    build_one iossim      arm64  iphonesimulator   "-mios-simulator-version-min=15.0"
    build_one tvos        arm64  appletvos         "-mtvos-version-min=15.0"
    build_one tvossim     arm64  appletvsimulator  "-mtvos-simulator-version-min=15.0"
    for lib in "${LIBS[@]}"; do
      make_xcframework "$lib"
    done
    echo "==> dynamic-framework xcframeworks in $ROOT/Frameworks"
    ;;
  *)
    echo "usage: $0 {macos|all}"; exit 1;;
esac
