#include "cff_audio_decoder.h"

#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

struct CFFAudioDecoder {
    AVCodecContext *ctx;
    AVPacket *packet;
    AVFrame *frame;
    SwrContext *swr;

    // Padded copy of the caller's packet: FFmpeg's bitstream readers over-read
    // past the end, so the input needs the same padding the video path uses.
    uint8_t *inbuf;
    int inbuf_cap;

    // Reusable interleaved S16 output buffer.
    uint8_t *out;
    int out_cap;

    int sample_rate;
    int channels;
};

static enum AVCodecID audio_codec_id(CFFAudioCodec codec) {
    switch (codec) {
        case CFF_AUDIO_VORBIS: return AV_CODEC_ID_VORBIS;
        case CFF_AUDIO_OPUS:   return AV_CODEC_ID_OPUS;
        case CFF_AUDIO_AAC:    return AV_CODEC_ID_AAC;
        case CFF_AUDIO_AC3:    return AV_CODEC_ID_AC3;
        case CFF_AUDIO_EAC3:   return AV_CODEC_ID_EAC3;
        case CFF_AUDIO_MP2:    return AV_CODEC_ID_MP2;
        default:               return AV_CODEC_ID_NONE;
    }
}

CFFAudioDecoder *cff_audio_create(CFFAudioCodec codec, int sample_rate, int channels,
                                  const uint8_t *extradata, int extradata_size) {
    enum AVCodecID id = audio_codec_id(codec);
    if (id == AV_CODEC_ID_NONE) return NULL;

    const AVCodec *avcodec = avcodec_find_decoder(id);
    if (!avcodec) return NULL;

    CFFAudioDecoder *dec = calloc(1, sizeof(CFFAudioDecoder));
    if (!dec) return NULL;

    dec->sample_rate = sample_rate > 0 ? sample_rate : 48000;
    dec->channels = channels > 0 ? channels : 2;

    dec->ctx = avcodec_alloc_context3(avcodec);
    dec->packet = av_packet_alloc();
    dec->frame = av_frame_alloc();
    if (!dec->ctx || !dec->packet || !dec->frame) {
        cff_audio_destroy(dec);
        return NULL;
    }

    dec->ctx->sample_rate = dec->sample_rate;
    av_channel_layout_default(&dec->ctx->ch_layout, dec->channels);

    // Vorbis carries its identification, comment and setup headers in the
    // container rather than the stream, so without this it cannot start.
    if (extradata && extradata_size > 0) {
        dec->ctx->extradata = av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!dec->ctx->extradata) { cff_audio_destroy(dec); return NULL; }
        memcpy(dec->ctx->extradata, extradata, extradata_size);
        dec->ctx->extradata_size = extradata_size;
    }

    if (avcodec_open2(dec->ctx, avcodec, NULL) < 0) {
        cff_audio_destroy(dec);
        return NULL;
    }
    return dec;
}

void cff_audio_destroy(CFFAudioDecoder *dec) {
    if (!dec) return;
    if (dec->swr) swr_free(&dec->swr);
    if (dec->out) av_freep(&dec->out);
    if (dec->inbuf) av_free(dec->inbuf);
    if (dec->frame) av_frame_free(&dec->frame);
    if (dec->packet) av_packet_free(&dec->packet);
    if (dec->ctx) avcodec_free_context(&dec->ctx);
    free(dec);
}

int cff_audio_feed(CFFAudioDecoder *dec, const uint8_t *data, int size, int64_t pts) {
    if (!dec || size <= 0) return dec ? 0 : -1;

    int need = size + AV_INPUT_BUFFER_PADDING_SIZE;
    if (dec->inbuf_cap < need) {
        uint8_t *nb = av_realloc(dec->inbuf, need);
        if (!nb) return -1;
        dec->inbuf = nb;
        dec->inbuf_cap = need;
    }
    memcpy(dec->inbuf, data, size);
    memset(dec->inbuf + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);

    dec->packet->data = dec->inbuf;
    dec->packet->size = size;
    dec->packet->pts = pts;
    dec->packet->dts = pts;
    int ret = avcodec_send_packet(dec->ctx, dec->packet);
    dec->packet->data = NULL;
    dec->packet->size = 0;
    // A packet the decoder can't use yet isn't fatal; the caller drains and retries.
    return (ret < 0 && ret != AVERROR(EAGAIN)) ? 0 : 0;
}

// Builds the converter to interleaved S16 once the decoder has told us what it
// actually produces, which can differ from what the container advertised.
static int ensure_swr(CFFAudioDecoder *dec, AVFrame *f) {
    if (dec->swr) return 0;

    AVChannelLayout out_layout;
    av_channel_layout_default(&out_layout, f->ch_layout.nb_channels);

    int ret = swr_alloc_set_opts2(&dec->swr,
                                  &out_layout, AV_SAMPLE_FMT_S16, f->sample_rate,
                                  &f->ch_layout, (enum AVSampleFormat)f->format, f->sample_rate,
                                  0, NULL);
    av_channel_layout_uninit(&out_layout);
    if (ret < 0 || !dec->swr) return -1;
    if (swr_init(dec->swr) < 0) { swr_free(&dec->swr); return -1; }

    dec->sample_rate = f->sample_rate;
    dec->channels = f->ch_layout.nb_channels;
    return 0;
}

int cff_audio_receive(CFFAudioDecoder *dec, CFFAudioFrame *out) {
    if (!dec || !out) return -1;

    av_frame_unref(dec->frame);
    if (avcodec_receive_frame(dec->ctx, dec->frame) < 0) return 0;

    AVFrame *f = dec->frame;
    if (f->nb_samples <= 0 || f->ch_layout.nb_channels <= 0) return 0;
    if (ensure_swr(dec, f) < 0) return -1;

    int channels = dec->channels;
    int needed = f->nb_samples * channels * 2;      // 2 bytes per S16 sample
    if (dec->out_cap < needed) {
        if (dec->out) av_freep(&dec->out);
        dec->out = av_malloc(needed);
        if (!dec->out) { dec->out_cap = 0; return -1; }
        dec->out_cap = needed;
    }

    uint8_t *dst = dec->out;
    int converted = swr_convert(dec->swr, &dst, f->nb_samples,
                                (const uint8_t **)f->extended_data, f->nb_samples);
    if (converted <= 0) return 0;

    out->data = dec->out;
    out->frames = converted;
    out->size = converted * channels * 2;
    out->pts = (f->best_effort_timestamp != AV_NOPTS_VALUE)
                 ? f->best_effort_timestamp
                 : f->pts;
    return 1;
}

int cff_audio_sample_rate(CFFAudioDecoder *dec) { return dec ? dec->sample_rate : 0; }
int cff_audio_channels(CFFAudioDecoder *dec) { return dec ? dec->channels : 0; }
