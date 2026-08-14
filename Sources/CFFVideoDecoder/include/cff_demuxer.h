#ifndef CFF_DEMUXER_H
#define CFF_DEMUXER_H

#include <stdint.h>
#include "cff_video_decoder.h"

// Thin C shim around libavformat for the containers TStreamKit does not demux
// itself: Matroska/WebM and MP4. MPEG-TS never comes through here, it has its
// own demuxer tuned for DVB broadcast.
//
// There is no protocol layer in this FFmpeg build. Bytes arrive through the
// read callback below, which the caller backs with its own HTTP download, so
// libavformat never touches the network.
//
// Timestamps are reported in 90 kHz to match the rest of the pipeline,
// regardless of the container's own time base.

typedef struct CFFDemuxer CFFDemuxer;

// Audio codecs a container can hand us. The ones Core Audio can decode are
// passed through compressed; the rest are decoded by libavcodec.
typedef enum {
    CFF_AUDIO_UNKNOWN = 0,
    CFF_AUDIO_AAC     = 1,
    CFF_AUDIO_AC3     = 2,
    CFF_AUDIO_EAC3    = 3,
    CFF_AUDIO_MP2     = 4,
    CFF_AUDIO_VORBIS  = 5,
    CFF_AUDIO_OPUS    = 6,
} CFFAudioCodec;

// What the container advertises, valid after cff_demux_open(). The extradata
// pointers are owned by the demuxer and stay valid until it is destroyed, so
// copy them if you need them longer.
typedef struct {
    int has_video;
    CFFCodec video_codec;
    int video_width;
    int video_height;
    const uint8_t *video_extradata;      // avcC / hvcC / CodecPrivate
    int video_extradata_size;
    // Sample (pixel) aspect ratio the container advertises, 0/0 if it says
    // nothing. Matroska keeps it in DisplayWidth/DisplayHeight and MP4 in the
    // pasp atom. It matters for codecs that cannot carry aspect information in
    // the bitstream: VP8 has no field for it at all, so for anamorphic WebM
    // this is the only place the display shape exists. H.264, HEVC and MPEG-2
    // signal it in the bitstream, which stays authoritative.
    int video_sar_num;
    int video_sar_den;

    int has_audio;
    CFFAudioCodec audio_codec;
    int audio_sample_rate;
    int audio_channels;
    const uint8_t *audio_extradata;      // AudioSpecificConfig, Vorbis headers, …
    int audio_extradata_size;
} CFFStreamInfo;

// One demuxed packet. `data` points into the demuxer's own packet buffer and is
// only valid until the next cff_demux_next_packet() call, so copy it out.
typedef struct {
    int is_video;         // 1 = video, 0 = audio
    const uint8_t *data;
    int size;
    int64_t pts;          // 90 kHz, or CFF_NOPTS
    int64_t dts;          // 90 kHz, or CFF_NOPTS
    int keyframe;
} CFFPacket;

#define CFF_NOPTS INT64_MIN

// Supplies bytes to libavformat. Fill `buf` with up to `size` bytes and return
// how many were written, 0 at end of stream, or negative on error. It is called
// on whichever thread drives cff_demux_open/next_packet and may block waiting
// for the network.
typedef int (*CFFReadCallback)(void *opaque, uint8_t *buf, int size);

CFFDemuxer *cff_demux_create(CFFReadCallback read, void *opaque);

void cff_demux_destroy(CFFDemuxer *d);

// Probes the container and identifies the streams. Blocks while it reads
// through the callback. Returns 0 on success, negative on error.
int cff_demux_open(CFFDemuxer *d);

// Fills `out` with what the container advertises. Call after cff_demux_open().
int cff_demux_stream_info(CFFDemuxer *d, CFFStreamInfo *out);

// Reads the next audio or video packet, skipping streams we don't follow.
// Returns 1 if `out` was filled, 0 at end of stream, negative on error.
int cff_demux_next_packet(CFFDemuxer *d, CFFPacket *out);

// Makes the pending read callback return end-of-stream so a blocked
// cff_demux_open/next_packet unwinds. Safe to call from another thread.
void cff_demux_interrupt(CFFDemuxer *d);

#endif // CFF_DEMUXER_H
