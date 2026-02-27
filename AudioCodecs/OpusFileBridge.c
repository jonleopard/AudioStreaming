#include "include/OpusFileBridge.h"

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <opus/opusfile.h>

struct OPRemoteStream {
    uint8_t *buf;
    size_t cap, head, tail, size;
    int eof;
    long long pos;
    long long total_pushed;
    pthread_mutex_t m;
    pthread_cond_t cv;
};

static size_t rb_write(struct OPRemoteStream *s, const uint8_t *src, size_t len) {
    size_t written = 0;
    while (written < len) {
        size_t free_space = s->cap - s->size;
        if (free_space == 0) break;
        size_t chunk = s->cap - s->tail;
        if (chunk > len - written) chunk = len - written;
        if (chunk > free_space) chunk = free_space;
        memcpy(s->buf + s->tail, src + written, chunk);
        s->tail = (s->tail + chunk) % s->cap;
        s->size += chunk;
        written += chunk;
    }
    return written;
}

static size_t rb_read(struct OPRemoteStream *s, uint8_t *dst, size_t len) {
    size_t nread = 0;
    while (nread < len && s->size > 0) {
        size_t chunk = s->cap - s->head;
        if (chunk > s->size) chunk = s->size;
        if (chunk > len - nread) chunk = len - nread;
        memcpy(dst + nread, s->buf + s->head, chunk);
        s->head = (s->head + chunk) % s->cap;
        s->size -= chunk;
        nread += chunk;
    }
    return nread;
}

OPStreamRef OPStreamCreate(size_t capacity_bytes) {
    struct OPRemoteStream *s = (struct OPRemoteStream *)calloc(1, sizeof(struct OPRemoteStream));
    if (!s) return NULL;
    s->buf = (uint8_t *)malloc(capacity_bytes);
    if (!s->buf) { free(s); return NULL; }
    s->cap = capacity_bytes;
    pthread_mutex_init(&s->m, NULL);
    pthread_cond_init(&s->cv, NULL);
    return s;
}

void OPStreamDestroy(OPStreamRef sr) {
    struct OPRemoteStream *s = (struct OPRemoteStream *)sr;
    if (!s) return;
    pthread_mutex_destroy(&s->m);
    pthread_cond_destroy(&s->cv);
    free(s->buf);
    free(s);
}

size_t OPStreamAvailableBytes(OPStreamRef sr) {
    struct OPRemoteStream *s = (struct OPRemoteStream *)sr;
    if (!s) return 0;
    pthread_mutex_lock(&s->m);
    size_t sz = s->size;
    pthread_mutex_unlock(&s->m);
    return sz;
}

void OPStreamPush(OPStreamRef sr, const uint8_t *data, size_t len) {
    struct OPRemoteStream *s = (struct OPRemoteStream *)sr;
    if (!s || !data || len == 0) return;

    pthread_mutex_lock(&s->m);
    size_t written_total = 0;
    while (written_total < len) {
        size_t w = rb_write(s, data + written_total, len - written_total);
        written_total += w;
        if (written_total < len) {
            pthread_cond_wait(&s->cv, &s->m);
        }
    }
    s->total_pushed += (long long)len;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
}

void OPStreamMarkEOF(OPStreamRef sr) {
    struct OPRemoteStream *s = (struct OPRemoteStream *)sr;
    if (!s) return;
    pthread_mutex_lock(&s->m);
    s->eof = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
}

static int op_read_cb(void *datasrc, unsigned char *ptr, int nbytes) {
    struct OPRemoteStream *s = (struct OPRemoteStream *)datasrc;
    if (!s || nbytes <= 0) return -1;

    pthread_mutex_lock(&s->m);

    if (s->size == 0 && s->eof) {
        pthread_mutex_unlock(&s->m);
        return 0;
    }

    if (s->size == 0) {
        pthread_mutex_unlock(&s->m);
        return 0;
    }

    size_t got = rb_read(s, ptr, (size_t)nbytes);
    s->pos += (long long)got;
    pthread_cond_broadcast(&s->cv);

    pthread_mutex_unlock(&s->m);
    return (int)got;
}

static int op_close_cb(void *datasrc) {
    (void)datasrc;
    return 0;
}

int OPOpen(OPStreamRef sr, OPFileRef *out_of) {
    struct OPRemoteStream *s = (struct OPRemoteStream *)sr;
    if (!s || !out_of) return -1;

    OpusFileCallbacks cbs;
    cbs.read = op_read_cb;
    cbs.seek = NULL;
    cbs.tell = NULL;
    cbs.close = op_close_cb;

    int error = 0;
    OggOpusFile *of = op_open_callbacks((void *)s, &cbs, NULL, 0, &error);
    if (!of) return error;

    *out_of = (OPFileRef)of;
    return 0;
}

void OPFree(OPFileRef fr) {
    OggOpusFile *of = (OggOpusFile *)fr;
    if (!of) return;
    op_free(of);
}

int OPGetInfo(OPFileRef fr, OPStreamInfo *out_info) {
    OggOpusFile *of = (OggOpusFile *)fr;
    if (!of || !out_info) return -1;

    const OpusHead *head = op_head(of, -1);
    if (!head) return -1;

    out_info->sample_rate = 48000;
    out_info->channels = head->channel_count;

    ogg_int64_t total = op_pcm_total(of, -1);
    if (total >= 0) {
        out_info->total_pcm = (long long)total;
        out_info->duration_seconds = (double)total / 48000.0;
    } else {
        out_info->total_pcm = -1;
        out_info->duration_seconds = -1.0;
    }

    return 0;
}

int OPReadFloat(OPFileRef fr, float *dst, int max_frames, int channels) {
    OggOpusFile *of = (OggOpusFile *)fr;
    if (!of || !dst || max_frames <= 0 || channels <= 0) return -1;

    int buf_size = max_frames * channels;
    int li = 0;
    int result = op_read_float(of, dst, buf_size, &li);

    // OP_HOLE (-3): gap in data, retry
    if (result == OP_HOLE) return 0;

    return result;
}

int OPSeekPCM(OPFileRef fr, long long pcm_offset) {
    OggOpusFile *of = (OggOpusFile *)fr;
    if (!of) return -1;
    return op_pcm_seek(of, (ogg_int64_t)pcm_offset);
}

int OPIsSeekable(OPFileRef fr) {
    OggOpusFile *of = (OggOpusFile *)fr;
    if (!of) return 0;
    return op_seekable(of);
}
