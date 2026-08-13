#ifndef CFF_AUDIO_DECODER_H
#define CFF_AUDIO_DECODER_H

#include <stdint.h>
#include "cff_demuxer.h"

// Decodes the audio codecs Core Audio cannot take. AAC, AC-3, E-AC-3 and MP2
// are passed through compressed to the system decoder and never come here;
// this is for Vorbis and Opus, which arrive in WebM and Matroska.
//
// Output is always interleaved signed 16-bit PCM, which is the plainest thing
// an AVSampleBufferAudioRenderer accepts and spares the caller from handling
// the planar float most of these decoders produce natively.

typedef struct CFFAudioDecoder CFFAudioDecoder;

typedef struct {
    const uint8_t *data;   // interleaved signed 16-bit
    int size;              // bytes
    int frames;            // sample frames (size / (2 * channels))
    int64_t pts;           // 90 kHz
} CFFAudioFrame;

// `extradata` is the container's codec setup record, which Vorbis cannot decode
// without: its three setup headers live there rather than in the stream.
// Returns NULL on failure.
CFFAudioDecoder *cff_audio_create(CFFAudioCodec codec, int sample_rate, int channels,
                                  const uint8_t *extradata, int extradata_size);

void cff_audio_destroy(CFFAudioDecoder *d);

// Feeds one compressed packet. Returns 0 on success, negative on a fatal error.
int cff_audio_feed(CFFAudioDecoder *d, const uint8_t *data, int size, int64_t pts);

// Pulls the next block of PCM. Returns 1 if `out` was filled, 0 if more input is
// needed. The data stays valid until the next cff_audio_* call.
int cff_audio_receive(CFFAudioDecoder *d, CFFAudioFrame *out);

// The output format, known after the first successful decode. Until then these
// report what was requested at creation.
int cff_audio_sample_rate(CFFAudioDecoder *d);
int cff_audio_channels(CFFAudioDecoder *d);

#endif // CFF_AUDIO_DECODER_H
