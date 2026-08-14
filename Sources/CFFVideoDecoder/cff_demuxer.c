#include "cff_demuxer.h"

#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>

// Size of the buffer libavformat reads through. 32 KB is the usual default and
// is comfortably more than a probe needs per call.
#define CFF_AVIO_BUFFER_SIZE (32 * 1024)

struct CFFDemuxer {
    AVFormatContext *fmt;
    AVIOContext *avio;
    AVPacket *packet;

    CFFReadCallback read;
    void *opaque;
    // Set from another thread to unblock a read that is waiting on the network.
    volatile int interrupted;

    int video_index;
    int audio_index;
};

// libavformat pulls through here. We forward to the host's callback and report
// end-of-stream once interrupted, so a teardown can't leave a thread parked in
// a blocking read forever.
static int cff_avio_read(void *opaque, uint8_t *buf, int buf_size) {
    CFFDemuxer *d = (CFFDemuxer *)opaque;
    if (d->interrupted) return AVERROR_EOF;
    int n = d->read(d->opaque, buf, buf_size);
    if (d->interrupted) return AVERROR_EOF;
    if (n == 0) return AVERROR_EOF;
    if (n < 0) return AVERROR(EIO);
    return n;
}

// Lets libavformat abandon a long probe when we're shutting down.
static int cff_avio_interrupt(void *opaque) {
    CFFDemuxer *d = (CFFDemuxer *)opaque;
    return d->interrupted;
}

CFFDemuxer *cff_demux_create(CFFReadCallback read, void *opaque) {
    if (!read) return NULL;
    CFFDemuxer *d = calloc(1, sizeof(CFFDemuxer));
    if (!d) return NULL;

    d->read = read;
    d->opaque = opaque;
    d->video_index = -1;
    d->audio_index = -1;
    d->packet = av_packet_alloc();
    if (!d->packet) { cff_demux_destroy(d); return NULL; }

    uint8_t *buffer = av_malloc(CFF_AVIO_BUFFER_SIZE);
    if (!buffer) { cff_demux_destroy(d); return NULL; }

    // write_flag 0, no seek callback: the stream is forward-only, which is what
    // a live transcode gives us anyway.
    d->avio = avio_alloc_context(buffer, CFF_AVIO_BUFFER_SIZE, 0, d, cff_avio_read, NULL, NULL);
    if (!d->avio) { av_free(buffer); cff_demux_destroy(d); return NULL; }
    d->avio->seekable = 0;

    return d;
}

void cff_demux_destroy(CFFDemuxer *d) {
    if (!d) return;
    if (d->fmt) {
        avformat_close_input(&d->fmt);        // also frees the AVIOContext's buffer
    } else if (d->avio) {
        if (d->avio->buffer) av_freep(&d->avio->buffer);
        avio_context_free(&d->avio);
    }
    if (d->packet) av_packet_free(&d->packet);
    free(d);
}

void cff_demux_interrupt(CFFDemuxer *d) {
    if (d) d->interrupted = 1;
}

int cff_demux_open(CFFDemuxer *d) {
    if (!d || !d->avio) return -1;

    d->fmt = avformat_alloc_context();
    if (!d->fmt) return -1;

    d->fmt->pb = d->avio;
    d->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    d->fmt->interrupt_callback.callback = cff_avio_interrupt;
    d->fmt->interrupt_callback.opaque = d;

    // Keep start-up latency down on a live stream: probing reads real seconds of
    // content before it reports, and we only need enough to identify the codecs.
    d->fmt->probesize = 512 * 1024;
    d->fmt->max_analyze_duration = 2 * AV_TIME_BASE;

    if (avformat_open_input(&d->fmt, NULL, NULL, NULL) < 0) {
        // On failure avformat_open_input frees and NULLs fmt, taking the AVIO
        // context with it. Drop our alias so destroy doesn't double-free.
        d->avio = NULL;
        return -1;
    }
    if (avformat_find_stream_info(d->fmt, NULL) < 0) return -1;

    d->video_index = av_find_best_stream(d->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    d->audio_index = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (d->video_index < 0 && d->audio_index < 0) return -1;
    return 0;
}

static CFFCodec map_video_codec(enum AVCodecID id, int *supported) {
    *supported = 1;
    switch (id) {
        case AV_CODEC_ID_H264:       return CFF_CODEC_H264;
        case AV_CODEC_ID_HEVC:       return CFF_CODEC_HEVC;
        case AV_CODEC_ID_MPEG2VIDEO: return CFF_CODEC_MPEG2;
        case AV_CODEC_ID_VP8:        return CFF_CODEC_VP8;
        default:                     *supported = 0; return CFF_CODEC_H264;
    }
}

static CFFAudioCodec map_audio_codec(enum AVCodecID id) {
    switch (id) {
        case AV_CODEC_ID_AAC:    return CFF_AUDIO_AAC;
        case AV_CODEC_ID_AC3:    return CFF_AUDIO_AC3;
        case AV_CODEC_ID_EAC3:   return CFF_AUDIO_EAC3;
        case AV_CODEC_ID_MP2:
        case AV_CODEC_ID_MP3:    return CFF_AUDIO_MP2;
        case AV_CODEC_ID_VORBIS: return CFF_AUDIO_VORBIS;
        case AV_CODEC_ID_OPUS:   return CFF_AUDIO_OPUS;
        default:                 return CFF_AUDIO_UNKNOWN;
    }
}

int cff_demux_stream_info(CFFDemuxer *d, CFFStreamInfo *out) {
    if (!d || !d->fmt || !out) return -1;
    memset(out, 0, sizeof(*out));

    if (d->video_index >= 0) {
        AVCodecParameters *p = d->fmt->streams[d->video_index]->codecpar;
        int supported = 0;
        CFFCodec codec = map_video_codec(p->codec_id, &supported);
        if (supported) {
            out->has_video = 1;
            out->video_codec = codec;
            out->video_width = p->width;
            out->video_height = p->height;
            out->video_extradata = p->extradata;
            out->video_extradata_size = p->extradata_size;
        } else {
            // Nothing we can decode: stop following it so packets aren't
            // handed out for a stream the player would only throw away.
            d->video_index = -1;
        }
    }

    if (d->audio_index >= 0) {
        AVCodecParameters *p = d->fmt->streams[d->audio_index]->codecpar;
        CFFAudioCodec codec = map_audio_codec(p->codec_id);
        if (codec != CFF_AUDIO_UNKNOWN) {
            out->has_audio = 1;
            out->audio_codec = codec;
            out->audio_sample_rate = p->sample_rate;
            out->audio_channels = p->ch_layout.nb_channels;
            out->audio_extradata = p->extradata;
            out->audio_extradata_size = p->extradata_size;
        } else {
            d->audio_index = -1;
        }
    }

    return (out->has_video || out->has_audio) ? 0 : -1;
}

static int64_t rescale_to_90k(int64_t ts, AVRational time_base) {
    if (ts == AV_NOPTS_VALUE) return CFF_NOPTS;
    return av_rescale_q(ts, time_base, (AVRational){1, 90000});
}

int cff_demux_next_packet(CFFDemuxer *d, CFFPacket *out) {
    if (!d || !d->fmt || !out) return -1;

    for (;;) {
        av_packet_unref(d->packet);
        int ret = av_read_frame(d->fmt, d->packet);
        if (ret == AVERROR_EOF) return 0;
        if (ret < 0) return d->interrupted ? 0 : -1;

        int index = d->packet->stream_index;
        if (index != d->video_index && index != d->audio_index) continue;

        AVRational tb = d->fmt->streams[index]->time_base;
        out->is_video = (index == d->video_index);
        out->data = d->packet->data;
        out->size = d->packet->size;
        out->pts = rescale_to_90k(d->packet->pts, tb);
        out->dts = rescale_to_90k(d->packet->dts, tb);
        out->keyframe = (d->packet->flags & AV_PKT_FLAG_KEY) ? 1 : 0;
        return 1;
    }
}
