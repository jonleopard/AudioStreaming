#ifndef OPUS_FILE_BRIDGE_H
#define OPUS_FILE_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

// Opaque refs for Swift-friendly API
typedef void *OPStreamRef;
typedef void *OPFileRef;

#ifdef __cplusplus
extern "C" {
#endif

// Stream info structure
typedef struct {
    int sample_rate;          // always 48000 for Opus
    int channels;
    long long total_pcm;      // op_pcm_total(of, -1), -1 if unknown/unseekable
    double duration_seconds;  // total_pcm / 48000.0, -1 if unknown
} OPStreamInfo;

// Stream lifecycle
OPStreamRef OPStreamCreate(size_t capacity_bytes);
void        OPStreamDestroy(OPStreamRef s);
size_t      OPStreamAvailableBytes(OPStreamRef s);

// Feeding data
void OPStreamPush(OPStreamRef s, const uint8_t *data, size_t len);
void OPStreamMarkEOF(OPStreamRef s);

// Decoder lifecycle
// Returns 0 on success, negative on error (libopusfile error codes)
int  OPOpen(OPStreamRef s, OPFileRef *out_of);
void OPFree(OPFileRef of);

// Query info; returns 0 on success
int OPGetInfo(OPFileRef of, OPStreamInfo *out_info);

// Read interleaved float32 PCM into dst.
// dst must hold at least max_frames * channels floats.
// Returns samples/channel read, 0 on EOF, <0 on error.
int OPReadFloat(OPFileRef of, float *dst, int max_frames, int channels);

// Seek to PCM sample offset (at 48 kHz). Returns 0 on success, <0 on error.
int OPSeekPCM(OPFileRef of, long long pcm_offset);

// Returns 1 if seekable, 0 if not.
int OPIsSeekable(OPFileRef of);

#ifdef __cplusplus
}
#endif

#endif // OPUS_FILE_BRIDGE_H
