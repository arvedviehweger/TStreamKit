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
