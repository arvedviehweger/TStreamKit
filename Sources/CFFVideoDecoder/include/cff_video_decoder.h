#ifndef CFF_VIDEO_DECODER_H
#define CFF_VIDEO_DECODER_H

#include <stdint.h>

// Thin C shim around libavcodec for decoding a raw H.264 / HEVC elementary
// stream to planar I420 frames. TStreamKit feeds the demuxed video PES bytes
// here and libavcodec does the NAL parsing, field/frame assembly, B-frame
// reordering and error concealment — the robustness VideoToolbox lacks for
// non-IDR interlaced broadcast.

typedef struct CFFVideoDecoder CFFVideoDecoder;

typedef enum {
    CFF_CODEC_H264 = 0,
    CFF_CODEC_HEVC = 1,
    CFF_CODEC_MPEG2 = 2,
    CFF_CODEC_VP8 = 3,
} CFFCodec;

// One decoded frame in planar I420 (kCVPixelFormatType_420YpCbCr8Planar):
// three separate Y, Cb, Cr planes. The pointers usually alias the decoder's own
// frame buffers (zero-copy) and stay valid until the next cff_* call.
typedef struct {
    int width;
    int height;
    int sar_num;          // sample (pixel) aspect ratio — 0/0 or 1/1 if square
    int sar_den;
    int64_t pts;          // stream timebase (passed through from the packet)
    const uint8_t *y;     // luma plane
    int y_stride;
    const uint8_t *u;     // Cb plane (width/2 × height/2)
    int u_stride;
    const uint8_t *v;     // Cr plane (width/2 × height/2)
    int v_stride;
} CFFFrame;

// Creates a decoder for a raw (Annex-B) elementary stream, as MPEG-TS carries
// it. Input is run through a parser that finds frame boundaries. Returns NULL
// on failure.
CFFVideoDecoder *cff_create(CFFCodec codec);

// Creates a decoder for packets that a container demuxer already framed, where
// `extradata` is the codec's setup record (avcC for H.264 in MP4/Matroska,
// hvcC for HEVC, CodecPrivate for VP8). No parser runs: each cff_feed() call
// must hand over exactly one packet.
//
// This is what makes length-prefixed H.264 work. In MP4 and Matroska the NAL
// units carry a length prefix instead of a start code, and the parameter sets
// live in the extradata rather than in the stream, so the decoder can only make
// sense of it once the extradata is set. Pass NULL/0 to leave it unset.
CFFVideoDecoder *cff_create_packetized(CFFCodec codec, const uint8_t *extradata, int extradata_size);

void cff_destroy(CFFVideoDecoder *dec);

// Feeds a chunk of the raw (Annex-B) elementary stream. The decoder parses and
// buffers internally; call cff_receive() afterwards to drain decoded frames.
// `pts`/`dts` are in 90 kHz and associated with the picture(s) in this chunk.
// Returns 0 on success, <0 on a fatal error.
int cff_feed(CFFVideoDecoder *dec, const uint8_t *data, int size, int64_t pts, int64_t dts);

// Pulls the next decoded I420 frame. Returns 1 if `out` was filled, 0 if more
// input is needed, <0 on error. The pixel data in `out` stays valid until the
// next cff_receive()/cff_feed()/cff_destroy() call.
int cff_receive(CFFVideoDecoder *dec, CFFFrame *out);

// Diagnostic snapshot for profiling the software path. The microsecond counters
// and frame count accumulate since the last cff_read_stats() call and reset on
// read; thread_count/thread_type and the dimensions reflect the live decoder.
typedef struct {
    int thread_count;     // worker threads the decoder actually opened
    int thread_type;      // bit0 = frame threading, bit1 = slice threading; 0 = single-threaded
    int width;
    int height;
    int interlaced;       // 1 if the last decoded frame was flagged interlaced
    int64_t frames;       // output frames since last read
    int64_t decode_us;    // wall time inside avcodec_receive_frame
    int64_t filter_us;    // wall time inside the bwdif filter pull + plane handoff
} CFFStats;

// Fills `out` with the accumulated diagnostics and resets the counters.
void cff_read_stats(CFFVideoDecoder *dec, CFFStats *out);

#endif // CFF_VIDEO_DECODER_H
