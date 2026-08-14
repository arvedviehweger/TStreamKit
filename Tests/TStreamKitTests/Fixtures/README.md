# Test fixtures

One-second 128x96 clips, one per container a transcoding server can serve. They
are tiny on purpose: the tests only need enough to check that a container is
identified, its codecs are reported and packets come out.

Regenerate with ffmpeg:

```sh
# Matroska, H.264 + AAC
ffmpeg -f lavfi -i testsrc=size=128x96:rate=25:duration=1 \
       -f lavfi -i "sine=frequency=440:duration=1" \
       -c:v libx264 -pix_fmt yuv420p -g 25 -c:a aac -b:a 32k probe.mkv

# WebM, VP8 + Vorbis
ffmpeg -f lavfi -i testsrc=size=128x96:rate=25:duration=1 \
       -f lavfi -i "sine=frequency=440:duration=1" \
       -c:v libvpx -b:v 100k -ac 2 -c:a vorbis -strict -2 -b:a 32k probe.webm

# WebM, anamorphic VP8: coded 120x90, displayed 160x90, so the pixels are 4:3.
# VP8 cannot signal an aspect ratio, so this only exists in the container and is
# what the pixel-aspect test guards. The numbers are chosen to stay integers:
# Matroska stores the display size as whole pixels, so a height of 96 at 16:9
# would round and the ratio would come out as 171:128 instead.
ffmpeg -f lavfi -i testsrc=size=120x90:rate=25:duration=1 \
       -c:v libvpx -b:v 100k -aspect 16:9 -an probe-anamorphic.webm

# Fragmented MP4, H.264 + AAC
ffmpeg -f lavfi -i testsrc=size=128x96:rate=25:duration=1 \
       -f lavfi -i "sine=frequency=440:duration=1" \
       -c:v libx264 -pix_fmt yuv420p -g 25 -c:a aac -b:a 32k \
       -movflags frag_keyframe+empty_moov probe.mp4

# Fragmented MP4, H.264 + Vorbis
ffmpeg -f lavfi -i testsrc=size=128x96:rate=25:duration=1 \
       -f lavfi -i "sine=frequency=440:duration=1" \
       -c:v libx264 -pix_fmt yuv420p -g 25 -ac 2 -c:a vorbis -strict -2 -b:a 32k \
       -movflags frag_keyframe+empty_moov probe-vorbis.mp4
```

The MP4 is fragmented because that is the only form a live stream can take: a
plain MP4 keeps its `moov` index at the end, so it cannot be played while it is
still being written.

`probe.adts` is half a second of 48 kHz mono AAC-LC as a raw bitstream, used to
check that libavcodec really decodes AAC and not just that a decoder opens:

```sh
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=48000" \
       -ac 1 -c:a aac -b:a 32k -f adts probe.adts
```

`probe-opus.webm` is the same one second clip with Opus audio, so the decoded
PCM path is covered for both codecs that use it:

```sh
ffmpeg -f lavfi -i testsrc=size=128x96:rate=25:duration=1 \
       -f lavfi -i "sine=frequency=440:duration=1" \
       -c:v libvpx -b:v 100k -ac 2 -c:a libopus -b:a 32k probe-opus.webm
```
