#include "cff_video_decoder.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/time.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libswscale/swscale.h>

struct CFFVideoDecoder {
    AVCodecContext *ctx;
    AVCodecParserContext *parser;
    AVPacket *packet;
    AVFrame *frame;

    // Padded copy of the caller's input — FFmpeg's bitstream readers over-read
    // up to AV_INPUT_BUFFER_PADDING_SIZE bytes past the end; without the padding
    // they fault (notably on the odd data that follows a continuity gap).
    uint8_t *inbuf;
    int inbuf_cap;

    // Deinterlacing filter graph (bwdif). Built lazily on the first frame.
    AVFilterGraph *graph;
    AVFilterContext *src_ctx;
    AVFilterContext *sink_ctx;
    AVFrame *filt_frame;
    int graph_ready;

    // Fallback conversion to I420, used only for non-4:2:0-planar decoder output
    // (e.g. 4:2:2 or 10-bit). The common 8-bit 4:2:0 path is zero-copy.
    struct SwsContext *sws;
    int sws_w, sws_h;
    enum AVPixelFormat sws_in_fmt;

    uint8_t *conv[4];
    int conv_linesize[4];
    int conv_w, conv_h;

    // Diagnostics, accumulated since the last cff_read_stats().
    int64_t stat_decode_us;
    int64_t stat_filter_us;
    int64_t stat_frames;
    int stat_w, stat_h, stat_interlaced;
};

CFFVideoDecoder *cff_create(CFFCodec codec) {
    enum AVCodecID id;
    switch (codec) {
        case CFF_CODEC_HEVC:  id = AV_CODEC_ID_HEVC; break;
        case CFF_CODEC_MPEG2: id = AV_CODEC_ID_MPEG2VIDEO; break;
        case CFF_CODEC_H264:
        default:              id = AV_CODEC_ID_H264; break;
    }
    const AVCodec *avcodec = avcodec_find_decoder(id);
    if (!avcodec) return NULL;

    CFFVideoDecoder *dec = calloc(1, sizeof(CFFVideoDecoder));
    if (!dec) return NULL;

    dec->ctx = avcodec_alloc_context3(avcodec);
    dec->parser = av_parser_init(id);
    dec->packet = av_packet_alloc();
    dec->frame = av_frame_alloc();
    if (!dec->ctx || !dec->parser || !dec->packet || !dec->frame) {
        cff_destroy(dec);
        return NULL;
    }

    dec->ctx->err_recognition = 0;
    dec->ctx->error_concealment = FF_EC_GUESS_MVS | FF_EC_DEBLOCK;
    dec->ctx->flags |= AV_CODEC_FLAG_OUTPUT_CORRUPT;
    dec->ctx->flags2 |= AV_CODEC_FLAG2_SHOW_ALL;
    dec->ctx->thread_count = 0;

    if (avcodec_open2(dec->ctx, avcodec, NULL) < 0) {
        cff_destroy(dec);
        return NULL;
    }
    return dec;
}

void cff_destroy(CFFVideoDecoder *dec) {
    if (!dec) return;
    if (dec->inbuf) av_free(dec->inbuf);
    if (dec->graph) avfilter_graph_free(&dec->graph);
    if (dec->filt_frame) av_frame_free(&dec->filt_frame);
    if (dec->sws) sws_freeContext(dec->sws);
    if (dec->conv[0]) av_freep(&dec->conv[0]);
    if (dec->frame) av_frame_free(&dec->frame);
    if (dec->packet) av_packet_free(&dec->packet);
    if (dec->parser) av_parser_close(dec->parser);
    if (dec->ctx) avcodec_free_context(&dec->ctx);
    free(dec);
}

int cff_feed(CFFVideoDecoder *dec, const uint8_t *data, int size, int64_t pts, int64_t dts) {
    if (!dec || size <= 0) return (dec ? 0 : -1);

    int need = size + AV_INPUT_BUFFER_PADDING_SIZE;
    if (dec->inbuf_cap < need) {
        uint8_t *nb = av_realloc(dec->inbuf, need);
        if (!nb) return -1;
        dec->inbuf = nb;
        dec->inbuf_cap = need;
    }
    memcpy(dec->inbuf, data, size);
    memset(dec->inbuf + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    data = dec->inbuf;

    while (size > 0) {
        int used = av_parser_parse2(dec->parser, dec->ctx,
                                    &dec->packet->data, &dec->packet->size,
                                    data, size, pts, dts, 0);
        if (used < 0) return -1;
        data += used;
        size -= used;
        if (dec->packet->size > 0) {
            dec->packet->pts = dec->parser->pts;
            dec->packet->dts = dec->parser->dts;
            (void)avcodec_send_packet(dec->ctx, dec->packet);
        }
        pts = AV_NOPTS_VALUE;
        dts = AV_NOPTS_VALUE;
    }
    return 0;
}

// Builds the bwdif deinterlace graph from the first decoded frame's parameters.
// `deint=interlaced` makes progressive content (e.g. 720p) pass through.
static int ensure_graph(CFFVideoDecoder *dec, AVFrame *frame) {
    if (dec->graph_ready) return 0;
    dec->graph = avfilter_graph_alloc();
    if (!dec->graph) return -1;

    AVRational sar = frame->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0) { sar.num = 1; sar.den = 1; }

    char args[512];
    snprintf(args, sizeof(args),
             "video_size=%dx%d:pix_fmt=%d:time_base=1/90000:pixel_aspect=%d/%d",
             frame->width, frame->height, frame->format, sar.num, sar.den);

    const AVFilter *buffersrc = avfilter_get_by_name("buffer");
    const AVFilter *buffersink = avfilter_get_by_name("buffersink");
    const AVFilter *bwdif = avfilter_get_by_name("bwdif");
    if (!buffersrc || !buffersink || !bwdif) return -1;

    AVFilterContext *bwdif_ctx = NULL;
    if (avfilter_graph_create_filter(&dec->src_ctx, buffersrc, "in", args, NULL, dec->graph) < 0) return -1;
    // bwdif modes (deint=interlaced leaves progressive content like 720p
    // untouched in either mode):
    //   send_field — one output frame per field (50p): smooth, broadcast-rate
    //                motion, but doubles all downstream per-frame work.
    //   send_frame — one output frame per field-pair (25p): half the downstream
    //                cost. Used for HD (1080i), where send_field 50p is the most
    //                CPU-intensive case (software decode + bwdif + plane copy).
    const char *bwdif_args = (frame->height > 576)
        ? "mode=send_frame:deint=interlaced"
        : "mode=send_field:deint=interlaced";
    if (avfilter_graph_create_filter(&bwdif_ctx, bwdif, "bwdif", bwdif_args, NULL, dec->graph) < 0) return -1;
    if (avfilter_graph_create_filter(&dec->sink_ctx, buffersink, "out", NULL, NULL, dec->graph) < 0) return -1;

    if (avfilter_link(dec->src_ctx, 0, bwdif_ctx, 0) < 0) return -1;
    if (avfilter_link(bwdif_ctx, 0, dec->sink_ctx, 0) < 0) return -1;
    if (avfilter_graph_config(dec->graph, NULL) < 0) return -1;

    dec->filt_frame = av_frame_alloc();
    if (!dec->filt_frame) return -1;
    dec->graph_ready = 1;
    return 0;
}

static int ensure_conv(CFFVideoDecoder *dec, int w, int h) {
    if (dec->conv[0] && dec->conv_w == w && dec->conv_h == h) return 0;
    if (dec->conv[0]) av_freep(&dec->conv[0]);
    if (av_image_alloc(dec->conv, dec->conv_linesize, w, h, AV_PIX_FMT_YUV420P, 16) < 0) return -1;
    dec->conv_w = w; dec->conv_h = h;
    return 0;
}

static int is_yuv420p(enum AVPixelFormat f) {
    return f == AV_PIX_FMT_YUV420P || f == AV_PIX_FMT_YUVJ420P;
}

// Exposes an AVFrame as planar I420 in `out`. For the common 8-bit 4:2:0 output
// the frame's own planes are handed through zero-copy; exotic formats (4:2:2,
// 10-bit, …) are converted once into the reusable `conv` buffer.
static int output_i420(CFFVideoDecoder *dec, AVFrame *f, CFFFrame *out) {
    int w = f->width, h = f->height;
    if (w <= 0 || h <= 0) return 0;

    const uint8_t *yp, *up, *vp;
    int ys, us, vs;
    enum AVPixelFormat in_fmt = (enum AVPixelFormat)f->format;

    if (is_yuv420p(in_fmt)) {
        yp = f->data[0]; ys = f->linesize[0];
        up = f->data[1]; us = f->linesize[1];
        vp = f->data[2]; vs = f->linesize[2];
    } else {
        if (ensure_conv(dec, w, h) < 0) return -1;
        if (!dec->sws || dec->sws_w != w || dec->sws_h != h || dec->sws_in_fmt != in_fmt) {
            if (dec->sws) sws_freeContext(dec->sws);
            dec->sws = sws_getContext(w, h, in_fmt, w, h, AV_PIX_FMT_YUV420P, SWS_BILINEAR, NULL, NULL, NULL);
            dec->sws_w = w; dec->sws_h = h; dec->sws_in_fmt = in_fmt;
            if (!dec->sws) return -1;
        }
        sws_scale(dec->sws, (const uint8_t *const *)f->data, f->linesize, 0, h, dec->conv, dec->conv_linesize);
        yp = dec->conv[0]; ys = dec->conv_linesize[0];
        up = dec->conv[1]; us = dec->conv_linesize[1];
        vp = dec->conv[2]; vs = dec->conv_linesize[2];
    }

    AVRational sar = f->sample_aspect_ratio;
    out->width = w;
    out->height = h;
    out->sar_num = sar.num;
    out->sar_den = sar.den;
    // Rescale the filtered frame's PTS from the sink's time base to 90 kHz —
    // the filter may use a different time base than the 1/90000 we fed in.
    AVRational sink_tb = av_buffersink_get_time_base(dec->sink_ctx);
    out->pts = (f->pts != AV_NOPTS_VALUE)
                 ? av_rescale_q(f->pts, sink_tb, (AVRational){1, 90000})
                 : 0;
    out->y = yp; out->y_stride = ys;
    out->u = up; out->u_stride = us;
    out->v = vp; out->v_stride = vs;
    return 1;
}

int cff_receive(CFFVideoDecoder *dec, CFFFrame *out) {
    if (!dec || !out) return -1;
    for (;;) {
        // Pull a deinterlaced frame out of the filter graph.
        if (dec->graph_ready) {
            // Release the frame exposed by the previous call — `out` aliased its
            // planes (zero-copy), so it had to stay referenced until now. Also
            // leaves filt_frame clean for av_buffersink_get_frame to fill.
            av_frame_unref(dec->filt_frame);
            int64_t t0 = av_gettime_relative();
            int fr = av_buffersink_get_frame(dec->sink_ctx, dec->filt_frame);
            if (fr >= 0) {
                int rc = output_i420(dec, dec->filt_frame, out);
                dec->stat_filter_us += av_gettime_relative() - t0;
                if (rc == 1) {                   // keep filt_frame referenced — out points into it
                    dec->stat_frames++;
                    return 1;
                }
                continue;                        // empty/invalid: unref on next loop, try next
            }
            dec->stat_filter_us += av_gettime_relative() - t0;
            if (fr != AVERROR(EAGAIN) && fr != AVERROR_EOF) return 0;
        }
        // Filter wants input — pull a decoded frame and push it in.
        int64_t t0 = av_gettime_relative();
        int ret = avcodec_receive_frame(dec->ctx, dec->frame);
        dec->stat_decode_us += av_gettime_relative() - t0;
        if (ret < 0) return 0; // EAGAIN/EOF/error → need more input
        if (dec->frame->width <= 0) { av_frame_unref(dec->frame); continue; }
        dec->stat_w = dec->frame->width;
        dec->stat_h = dec->frame->height;
        dec->stat_interlaced = (dec->frame->flags & AV_FRAME_FLAG_INTERLACED) ? 1 : 0;
        if (ensure_graph(dec, dec->frame) < 0) { av_frame_unref(dec->frame); return -1; }
        // Feed the filter the corrected display PTS (raw frame->pts can be
        // unset/NOPTS after B-frame reordering, which mis-times the output).
        dec->frame->pts = dec->frame->best_effort_timestamp;
        (void)av_buffersrc_add_frame_flags(dec->src_ctx, dec->frame, AV_BUFFERSRC_FLAG_KEEP_REF);
        av_frame_unref(dec->frame);
    }
}

void cff_read_stats(CFFVideoDecoder *dec, CFFStats *out) {
    if (!out) return;
    if (!dec) { memset(out, 0, sizeof(*out)); return; }
    out->thread_count = dec->ctx ? dec->ctx->thread_count : 0;
    out->thread_type = dec->ctx ? dec->ctx->active_thread_type : 0;
    out->width = dec->stat_w;
    out->height = dec->stat_h;
    out->interlaced = dec->stat_interlaced;
    out->frames = dec->stat_frames;
    out->decode_us = dec->stat_decode_us;
    out->filter_us = dec->stat_filter_us;
    dec->stat_frames = 0;
    dec->stat_decode_us = 0;
    dec->stat_filter_us = 0;
}
