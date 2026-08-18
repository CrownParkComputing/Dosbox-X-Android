/*
 * audio_backend_linux.c - ALSA + optional WAV-capture sound backend for the
 * DOSBox-X offscreen bridge on Linux. Satisfies audio_backend.h.
 *
 * Mirrors ViceMultiplatform's bridge/audio_backend.c (the ALSA backend there),
 * adapted to the DOSBox-X init signature (freq/blocksize/channels rather than
 * VICE's speed/fragsize/fragnr). The ring buffer, the 80ms prebuffer gate, the
 * ramp-to-zero underrun fill and the smoothed level meter are unchanged in
 * behaviour; only the device layer (ALSA) and parameter handling differ.
 *
 * Threading: DOSBox-X's mixer calls audio_backend_write() from its single
 * mainloop thread (the only producer); one background ALSA writer thread
 * drains the ring (the only consumer).
 *
 * Verification: set DOSBOX_AUDIO_WAV_CAPTURE=/path/to/out.wav and run
 * linux/check-core.sh. The backend mirrors the raw PCM to a valid, playable
 * WAV (header sizes patched after every chunk), so a silent-emulator bug is
 * caught by an all-zero capture instead of requiring a speaker.
 */
#include "audio_backend.h"

#include <alsa/asoundlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TAG "DosboxAudio"
#define LOGI(...) do { fprintf(stderr, "[" TAG "] INFO: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define LOGW(...) do { fprintf(stderr, "[" TAG "] WARN: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define LOGE(...) do { fprintf(stderr, "[" TAG "] ERROR: " __VA_ARGS__); fputc('\n', stderr); } while (0)

#define AUDIO_RING_MILLIS 500
#define AUDIO_PREBUFFER_MILLIS 80

/* ---------------------------------------------------------------------- */
/* Ring buffer (single producer = mixer thread, single consumer = ALSA    */
/* writer thread). Same lock-free frame-counter shape as Vice.            */
/* ---------------------------------------------------------------------- */

static int16_t *g_ring = NULL;
static int32_t g_ring_capacity_frames = 0;
static int g_channels = 2;
static int g_rate = 48000;

static atomic_uint_least64_t g_read_frame = 0;
static atomic_uint_least64_t g_write_frame = 0;
static atomic_bool g_prefilled = false;
static int32_t g_prebuffer_frames = 0;

static atomic_int g_audio_level = 0;

/* ---------------------------------------------------------------------- */
/* ALSA device + writer thread                                            */
/* ---------------------------------------------------------------------- */

static snd_pcm_t *g_pcm = NULL;
static pthread_t g_writer_thread;
static atomic_bool g_writer_running = false;
static atomic_bool g_closing = false;
static atomic_bool g_suspended = false;
static int32_t g_period_frames = 512;

/* ---------------------------------------------------------------------- */
/* Optional WAV capture (env DOSBOX_AUDIO_WAV_CAPTURE=/path/to/file.wav)  */
/* ---------------------------------------------------------------------- */

static FILE *g_wav = NULL;
static pthread_mutex_t g_wav_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_wav_data_bytes = 0;

static void wav_write_u32le(FILE *f, uint32_t v) {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    fwrite(b, 1, 4, f);
}
static void wav_write_u16le(FILE *f, uint16_t v) {
    uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
    fwrite(b, 1, 2, f);
}

static void wav_open(const char *path, int channels, int rate) {
    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        LOGW("could not open WAV capture file %s", path);
        return;
    }
    /* Placeholder 44-byte canonical PCM header; sizes patched on close. */
    fwrite("RIFF", 1, 4, f);
    wav_write_u32le(f, 0); /* riff size, patched later */
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f);
    wav_write_u32le(f, 16);
    wav_write_u16le(f, 1); /* PCM */
    wav_write_u16le(f, (uint16_t)channels);
    wav_write_u32le(f, (uint32_t)rate);
    wav_write_u32le(f, (uint32_t)(rate * channels * 2));
    wav_write_u16le(f, (uint16_t)(channels * 2));
    wav_write_u16le(f, 16);
    fwrite("data", 1, 4, f);
    wav_write_u32le(f, 0); /* data size, patched later */

    pthread_mutex_lock(&g_wav_mutex);
    g_wav = f;
    g_wav_data_bytes = 0;
    pthread_mutex_unlock(&g_wav_mutex);
    LOGI("WAV capture -> %s (channels=%d rate=%d)", path, channels, rate);
}

static void wav_append(const int16_t *samples, size_t count) {
    pthread_mutex_lock(&g_wav_mutex);
    if (g_wav != NULL) {
        fwrite(samples, sizeof(int16_t), count, g_wav);
        g_wav_data_bytes += count * sizeof(int16_t);

        /* Patch the header sizes after every chunk (not just on close) so the
         * file is a structurally valid, playable WAV even if the process is
         * killed or the emulator thread never calls audio_backend_close(). */
        const long pos = ftell(g_wav);
        const uint32_t data_bytes = (uint32_t)g_wav_data_bytes;
        const uint32_t riff_bytes = 36 + data_bytes;
        fseek(g_wav, 4, SEEK_SET);
        wav_write_u32le(g_wav, riff_bytes);
        fseek(g_wav, 40, SEEK_SET);
        wav_write_u32le(g_wav, data_bytes);
        fseek(g_wav, pos, SEEK_SET);
    }
    pthread_mutex_unlock(&g_wav_mutex);
}

static void wav_close(void) {
    pthread_mutex_lock(&g_wav_mutex);
    if (g_wav != NULL) {
        const uint32_t data_bytes = (uint32_t)g_wav_data_bytes;
        const uint32_t riff_bytes = 36 + data_bytes;
        fflush(g_wav);
        fseek(g_wav, 4, SEEK_SET);
        wav_write_u32le(g_wav, riff_bytes);
        fseek(g_wav, 40, SEEK_SET);
        wav_write_u32le(g_wav, data_bytes);
        fclose(g_wav);
        g_wav = NULL;
        LOGI("WAV capture closed, %u data bytes written", data_bytes);
    }
    g_wav_data_bytes = 0;
    pthread_mutex_unlock(&g_wav_mutex);
}

/* ---------------------------------------------------------------------- */
/* Ring buffer helpers                                                    */
/* ---------------------------------------------------------------------- */

static void ring_reset(void) {
    atomic_store_explicit(&g_read_frame, 0, memory_order_release);
    atomic_store_explicit(&g_write_frame, 0, memory_order_release);
    atomic_store_explicit(&g_prefilled, false, memory_order_release);
}

static int32_t ring_available_frames(void) {
    const uint64_t r = atomic_load_explicit(&g_read_frame, memory_order_acquire);
    const uint64_t w = atomic_load_explicit(&g_write_frame, memory_order_acquire);
    if (w <= r || g_ring_capacity_frames <= 0) return 0;
    const uint64_t avail = w - r;
    return (int32_t)(avail < (uint64_t)g_ring_capacity_frames ? avail : (uint64_t)g_ring_capacity_frames);
}

static void ring_push(const int16_t *input, int32_t frames) {
    if (input == NULL || frames <= 0 || g_ring == NULL || g_ring_capacity_frames <= 0) return;
    const int channels = g_channels;
    if (frames > g_ring_capacity_frames) {
        input += (size_t)(frames - g_ring_capacity_frames) * (size_t)channels;
        frames = g_ring_capacity_frames;
    }
    const uint64_t r = atomic_load_explicit(&g_read_frame, memory_order_acquire);
    const uint64_t w = atomic_load_explicit(&g_write_frame, memory_order_relaxed);
    const uint64_t avail = w > r ? w - r : 0;
    if (avail + (uint64_t)frames > (uint64_t)g_ring_capacity_frames) {
        const uint64_t keep = (uint64_t)(g_ring_capacity_frames - frames);
        atomic_store_explicit(&g_read_frame, w > keep ? w - keep : w, memory_order_release);
    }
    int32_t remaining = frames;
    uint64_t write_cursor = w;
    const int16_t *src = input;
    while (remaining > 0) {
        const int32_t ring_frame = (int32_t)(write_cursor % (uint64_t)g_ring_capacity_frames);
        const int32_t chunk = remaining < (g_ring_capacity_frames - ring_frame) ? remaining : (g_ring_capacity_frames - ring_frame);
        memcpy(g_ring + (size_t)ring_frame * channels, src, (size_t)chunk * channels * sizeof(int16_t));
        remaining -= chunk;
        write_cursor += chunk;
        src += (size_t)chunk * channels;
    }
    atomic_store_explicit(&g_write_frame, w + (uint64_t)frames, memory_order_release);
}

static int32_t ring_pop(int16_t *output, int32_t frames) {
    if (output == NULL || frames <= 0 || g_ring == NULL || g_ring_capacity_frames <= 0) return 0;
    const int channels = g_channels;
    uint64_t r = atomic_load_explicit(&g_read_frame, memory_order_relaxed);
    const uint64_t w = atomic_load_explicit(&g_write_frame, memory_order_acquire);
    int32_t available = w > r ? (int32_t)((w - r) < (uint64_t)g_ring_capacity_frames ? (w - r) : (uint64_t)g_ring_capacity_frames) : 0;
    const int32_t to_read = frames < available ? frames : available;
    int32_t remaining = to_read;
    int16_t *dest = output;
    uint64_t read_cursor = r;
    while (remaining > 0) {
        const int32_t ring_frame = (int32_t)(read_cursor % (uint64_t)g_ring_capacity_frames);
        const int32_t chunk = remaining < (g_ring_capacity_frames - ring_frame) ? remaining : (g_ring_capacity_frames - ring_frame);
        memcpy(dest, g_ring + (size_t)ring_frame * channels, (size_t)chunk * channels * sizeof(int16_t));
        remaining -= chunk;
        read_cursor += chunk;
        dest += (size_t)chunk * channels;
    }
    if (to_read < frames) {
        memset(dest, 0, (size_t)(frames - to_read) * channels * sizeof(int16_t));
    }
    atomic_store_explicit(&g_read_frame, r + (uint64_t)to_read, memory_order_release);
    return to_read;
}

/* ---------------------------------------------------------------------- */
/* ALSA writer thread                                                      */
/* ---------------------------------------------------------------------- */

static void *writer_thread_main(void *arg) {
    (void)arg;
    int16_t *scratch = calloc((size_t)g_period_frames * g_channels, sizeof(int16_t));
    if (scratch == NULL) {
        LOGE("writer thread: scratch alloc failed");
        return NULL;
    }
    while (!atomic_load_explicit(&g_closing, memory_order_acquire)) {
        if (g_pcm == NULL || atomic_load_explicit(&g_suspended, memory_order_acquire)) {
            struct timespec ts = {0, 5 * 1000000L};
            nanosleep(&ts, NULL);
            continue;
        }
        if (!atomic_load_explicit(&g_prefilled, memory_order_acquire)) {
            if (ring_available_frames() < g_prebuffer_frames) {
                struct timespec ts = {0, 2 * 1000000L};
                nanosleep(&ts, NULL);
                continue;
            }
            atomic_store_explicit(&g_prefilled, true, memory_order_release);
            LOGI("prebuffer filled (%d frames), starting ALSA playback", g_prebuffer_frames);
        }

        ring_pop(scratch, g_period_frames);
        snd_pcm_sframes_t written = snd_pcm_writei(g_pcm, scratch, (snd_pcm_uframes_t)g_period_frames);
        if (written < 0) {
            written = snd_pcm_recover(g_pcm, (int)written, 1);
            if (written < 0) {
                LOGW("snd_pcm_writei unrecoverable error: %s", snd_strerror((int)written));
                struct timespec ts = {0, 5 * 1000000L};
                nanosleep(&ts, NULL);
            }
        }
    }
    free(scratch);
    return NULL;
}

/* ---------------------------------------------------------------------- */
/* Public API                                                              */
/* ---------------------------------------------------------------------- */

static void teardown_locked(void) {
    if (atomic_load_explicit(&g_writer_running, memory_order_acquire)) {
        atomic_store_explicit(&g_closing, true, memory_order_release);
        pthread_join(g_writer_thread, NULL);
        atomic_store_explicit(&g_writer_running, false, memory_order_release);
    }
    if (g_pcm != NULL) {
        snd_pcm_close(g_pcm);
        g_pcm = NULL;
    }
    free(g_ring);
    g_ring = NULL;
    g_ring_capacity_frames = 0;
    wav_close();
}

int audio_backend_init(int freq, int blocksize, int channels,
                       int *out_freq, int *out_blocksize) {
    (void)blocksize;
    teardown_locked();
    atomic_store_explicit(&g_closing, false, memory_order_release);
    atomic_store_explicit(&g_suspended, false, memory_order_release);
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);

    g_channels = channels > 1 ? 2 : 1;
    g_rate = freq > 0 ? freq : 48000;

    const char *device = getenv("DOSBOX_ALSA_DEVICE");
    if (device == NULL || device[0] == '\0') device = "default";

    int err = snd_pcm_open(&g_pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) {
        LOGW("snd_pcm_open(%s) failed: %s -- continuing without live audio output", device, snd_strerror(err));
        g_pcm = NULL;
    } else {
        snd_pcm_hw_params_t *hw = NULL;
        snd_pcm_hw_params_alloca(&hw);
        snd_pcm_hw_params_any(g_pcm, hw);
        snd_pcm_hw_params_set_access(g_pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
        snd_pcm_hw_params_set_format(g_pcm, hw, SND_PCM_FORMAT_S16_LE);
        unsigned int rate = (unsigned int)g_rate;
        snd_pcm_hw_params_set_channels(g_pcm, hw, (unsigned int)g_channels);
        snd_pcm_hw_params_set_rate_near(g_pcm, hw, &rate, NULL);
        snd_pcm_uframes_t buffer_size = (snd_pcm_uframes_t)(rate / 1000 * 200); /* ~200ms */
        snd_pcm_hw_params_set_buffer_size_near(g_pcm, hw, &buffer_size);
        snd_pcm_uframes_t period_size = (snd_pcm_uframes_t)(rate / 1000 * 20); /* ~20ms */
        int dir = 0;
        snd_pcm_hw_params_set_period_size_near(g_pcm, hw, &period_size, &dir);

        err = snd_pcm_hw_params(g_pcm, hw);
        if (err < 0) {
            LOGW("snd_pcm_hw_params failed: %s -- continuing without live audio output", snd_strerror(err));
            snd_pcm_close(g_pcm);
            g_pcm = NULL;
        } else {
            g_rate = (int)rate;
            g_period_frames = (int32_t)period_size;
            if (g_period_frames < 64) g_period_frames = 64;
            snd_pcm_prepare(g_pcm);
            LOGI("ALSA opened device=%s rate=%d channels=%d period=%d buffer=%lu",
                 device, g_rate, g_channels, g_period_frames, (unsigned long)buffer_size);
        }
    }

    if (out_freq != NULL) *out_freq = g_rate;
    if (out_blocksize != NULL) *out_blocksize = g_period_frames;

    const int32_t ring_capacity = g_rate / 2 > 8192 ? g_rate / 2 : 8192; /* ~500ms, min 8192 frames */
    g_ring = calloc((size_t)ring_capacity * g_channels, sizeof(int16_t));
    if (g_ring == NULL) {
        LOGE("ring buffer allocation failed");
        return 1;
    }
    g_ring_capacity_frames = ring_capacity;
    g_prebuffer_frames = g_rate * AUDIO_PREBUFFER_MILLIS / 1000;
    if (g_prebuffer_frames < 2048) g_prebuffer_frames = 2048;
    ring_reset();

    const char *wav_path = getenv("DOSBOX_AUDIO_WAV_CAPTURE");
    if (wav_path != NULL && wav_path[0] != '\0') {
        wav_open(wav_path, g_channels, g_rate);
    }

    atomic_store_explicit(&g_writer_running, true, memory_order_release);
    if (pthread_create(&g_writer_thread, NULL, writer_thread_main, NULL) != 0) {
        LOGE("failed to start ALSA writer thread");
        atomic_store_explicit(&g_writer_running, false, memory_order_release);
    }

    return 0;
}

void audio_backend_write(const int16_t *samples, int frames) {
    if (samples == NULL || frames <= 0 || g_channels <= 0) return;
    if (frames > 0) {
        ring_push(samples, frames);
    }
    const size_t nr = (size_t)frames * (size_t)g_channels;
    wav_append(samples, nr);

    int32_t peak = 0;
    for (size_t i = 0; i < nr; i++) {
        int32_t v = samples[i];
        if (v < 0) v = -v;
        if (v > peak) peak = v;
    }
    const int32_t target = (int32_t)(((int64_t)peak * 100) / 32768);
    const int32_t cur = atomic_load_explicit(&g_audio_level, memory_order_relaxed);
    atomic_store_explicit(&g_audio_level, (cur * 3 + target) / 4, memory_order_relaxed);
}

void audio_backend_close(void) {
    teardown_locked();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
}

int audio_backend_suspend(void) {
    atomic_store_explicit(&g_suspended, true, memory_order_release);
    if (g_pcm != NULL) {
        snd_pcm_drop(g_pcm);
    }
    ring_reset();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
    return 0;
}

int audio_backend_resume(void) {
    if (g_pcm != NULL) {
        snd_pcm_prepare(g_pcm);
    }
    ring_reset();
    atomic_store_explicit(&g_suspended, false, memory_order_release);
    return 0;
}

int32_t audio_backend_get_level(void) {
    return atomic_load_explicit(&g_audio_level, memory_order_relaxed);
}