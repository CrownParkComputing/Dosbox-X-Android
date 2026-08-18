/*
 * audio_backend_android.c - AAudio sound backend for the DOSBox-X offscreen
 * bridge on Android. Satisfies audio_backend.h.
 *
 * Mirrors ViceMultiplatform's bridge/audio_backend_android.c (and ultimately
 * VICEAndroid's AAudio ring buffer / prebuffer gate), adapted to this bridge's
 * init signature. Real AAudio output, not a silent stub: the mixer's render
 * thread calls audio_backend_write() to push PCM into a lock-free ring, and an
 * AAudio data callback (running on AAudio's own high-priority realtime thread)
 * pulls frames back out, gated by an 80ms prebuffer fill.
 *
 * This exists so the core does NOT depend on SDL2's Android audio driver,
 * which needs org.libsdl.app.SDLAudioManager and a live SDL JNI environment
 * that a Flutter host cannot provide.
 */
#include "audio_backend.h"

#include <aaudio/AAudio.h>
#include <android/log.h>

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define TAG "DosboxAudio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define AUDIO_RING_MILLIS 500
#define AUDIO_PREBUFFER_MILLIS 80

/* ---------------------------------------------------------------------- */
/* Ring buffer (single producer = mixer thread, single consumer = the     */
/* AAudio data callback thread).                                          */
/* ---------------------------------------------------------------------- */

static int16_t *g_ring = NULL;
static atomic_int g_ring_capacity_frames = 0;
static int g_channels = 2;
static int g_rate = 48000;

static atomic_uint_least64_t g_read_frame = 0;
static atomic_uint_least64_t g_write_frame = 0;
static atomic_bool g_prefilled = false;
static atomic_int g_prebuffer_frames = 0;
static int16_t g_last_output[2] = {0, 0};

static atomic_int g_audio_level = 0;
static atomic_int g_drop_log_count = 0;
static atomic_int g_xrun_log_count = 0;
static atomic_int g_callback_log_count = 0;

static AAudioStream *g_stream = NULL;

static void ring_reset(void) {
    atomic_store_explicit(&g_read_frame, 0, memory_order_release);
    atomic_store_explicit(&g_write_frame, 0, memory_order_release);
    atomic_store_explicit(&g_prefilled, false, memory_order_release);
    g_last_output[0] = 0;
    g_last_output[1] = 0;
}

static int32_t ring_available_frames(void) {
    const uint64_t r = atomic_load_explicit(&g_read_frame, memory_order_acquire);
    const uint64_t w = atomic_load_explicit(&g_write_frame, memory_order_acquire);
    const int32_t capacity = atomic_load_explicit(&g_ring_capacity_frames, memory_order_acquire);
    if (w <= r || capacity <= 0) return 0;
    const uint64_t avail = w - r;
    return (int32_t)(avail < (uint64_t)capacity ? avail : (uint64_t)capacity);
}

static void ring_push(const int16_t *input, int32_t frames) {
    const int32_t capacity = atomic_load_explicit(&g_ring_capacity_frames, memory_order_acquire);
    const int channels = g_channels;
    if (input == NULL || frames <= 0 || g_ring == NULL || capacity <= 0 || channels <= 0) return;

    if (frames > capacity) {
        input += (size_t)(frames - capacity) * (size_t)channels;
        frames = capacity;
    }

    const uint64_t r = atomic_load_explicit(&g_read_frame, memory_order_acquire);
    const uint64_t w = atomic_load_explicit(&g_write_frame, memory_order_relaxed);
    const uint64_t avail = w > r ? w - r : 0;
    if (avail + (uint64_t)frames > (uint64_t)capacity) {
        const uint64_t keep = (uint64_t)(capacity - frames);
        atomic_store_explicit(&g_read_frame, w > keep ? w - keep : w, memory_order_release);
        int drop_log = atomic_fetch_add(&g_drop_log_count, 1);
        if (drop_log < 8) {
            LOGW("ring full; dropping old frames available=%llu incoming=%d capacity=%d",
                 (unsigned long long)avail, frames, capacity);
        }
    }

    int32_t remaining = frames;
    uint64_t write_cursor = w;
    const int16_t *src = input;
    while (remaining > 0) {
        const int32_t ring_frame = (int32_t)(write_cursor % (uint64_t)capacity);
        const int32_t chunk = remaining < (capacity - ring_frame) ? remaining : (capacity - ring_frame);
        memcpy(g_ring + (size_t)ring_frame * channels, src, (size_t)chunk * channels * sizeof(int16_t));
        remaining -= chunk;
        write_cursor += chunk;
        src += (size_t)chunk * channels;
    }
    atomic_store_explicit(&g_write_frame, w + (uint64_t)frames, memory_order_release);
}

/* Linear ramp-to-zero from the last real sample while the ring refills, to
 * avoid a hard discontinuity (same trick as Vice's fill_from_last_sample). */
static void fill_from_last_sample(int16_t *output, int32_t frames, int channels) {
    if (output == NULL || frames <= 0 || channels <= 0) return;
    const int16_t left = g_last_output[0];
    const int16_t right = channels > 1 ? g_last_output[1] : left;
    for (int32_t frame = 0; frame < frames; frame++) {
        const int32_t scale = frames - frame;
        output[(size_t)frame * channels] = (int16_t)(((int32_t)left * scale) / frames);
        if (channels > 1) {
            output[(size_t)frame * channels + 1] = (int16_t)(((int32_t)right * scale) / frames);
        }
    }
    g_last_output[0] = 0;
    g_last_output[1] = 0;
}

static aaudio_data_callback_result_t audio_data_callback(
        AAudioStream *stream, void *user_data, void *audio_data, int32_t num_frames) {
    (void)stream;
    (void)user_data;
    int16_t *output = (int16_t *)audio_data;
    const int channels = g_channels;
    const int32_t capacity = atomic_load_explicit(&g_ring_capacity_frames, memory_order_acquire);
    if (output == NULL || num_frames <= 0 || channels <= 0 || capacity <= 0 || g_ring == NULL) {
        return AAUDIO_CALLBACK_RESULT_CONTINUE;
    }

    int32_t available = ring_available_frames();
    const int32_t configured_prebuffer = atomic_load_explicit(&g_prebuffer_frames, memory_order_acquire);
    int32_t prebuffer = configured_prebuffer > 0 ? configured_prebuffer : 2048;
    if (prebuffer < 1024) prebuffer = 1024;
    if (prebuffer > capacity / 3) prebuffer = capacity / 3;

    int cb_log = atomic_fetch_add(&g_callback_log_count, 1);
    if (cb_log < 8 || (cb_log % 500) == 0) {
        LOGI("callback #%d num_frames=%d available=%d prebuffer=%d prefilled=%d",
             cb_log + 1, num_frames, available, prebuffer,
             atomic_load_explicit(&g_prefilled, memory_order_acquire) ? 1 : 0);
    }

    if (!atomic_load_explicit(&g_prefilled, memory_order_acquire) && available < prebuffer) {
        fill_from_last_sample(output, num_frames, channels);
        return AAUDIO_CALLBACK_RESULT_CONTINUE;
    }
    if (!atomic_exchange_explicit(&g_prefilled, true, memory_order_acq_rel)) {
        LOGI("PREFILLED: first real audio output available=%d prebuffer=%d", available, prebuffer);
    }

    uint64_t read = atomic_load_explicit(&g_read_frame, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&g_write_frame, memory_order_acquire);
    if (write < read) {
        read = write;
        atomic_store_explicit(&g_read_frame, read, memory_order_release);
        available = 0;
    } else {
        const uint64_t a = write - read;
        available = (int32_t)(a < (uint64_t)capacity ? a : (uint64_t)capacity);
    }

    const int32_t frames_to_read = num_frames < available ? num_frames : available;
    int32_t remaining = frames_to_read;
    int16_t *dest = output;
    uint64_t read_cursor = read;
    while (remaining > 0) {
        const int32_t ring_frame = (int32_t)(read_cursor % (uint64_t)capacity);
        const int32_t chunk = remaining < (capacity - ring_frame) ? remaining : (capacity - ring_frame);
        memcpy(dest, g_ring + (size_t)ring_frame * channels, (size_t)chunk * channels * sizeof(int16_t));
        remaining -= chunk;
        read_cursor += chunk;
        dest += (size_t)chunk * channels;
    }

    if (frames_to_read > 0) {
        const int16_t *last = output + (size_t)(frames_to_read - 1) * channels;
        g_last_output[0] = last[0];
        g_last_output[1] = channels > 1 ? last[1] : last[0];
    }

    if (frames_to_read < num_frames) {
        fill_from_last_sample(dest, num_frames - frames_to_read, channels);
        int xrun_log = atomic_fetch_add(&g_xrun_log_count, 1);
        if (xrun_log < 8) {
            LOGW("callback underrun read=%d requested=%d available=%d", frames_to_read, num_frames, available);
        }
    }

    atomic_store_explicit(&g_read_frame, read + (uint64_t)frames_to_read, memory_order_release);
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

/* ---------------------------------------------------------------------- */
/* Public API                                                              */
/* ---------------------------------------------------------------------- */

static void teardown_stream(void) {
    if (g_stream != NULL) {
        AAudioStream_requestStop(g_stream);
        AAudioStream_close(g_stream);
        g_stream = NULL;
    }
    free(g_ring);
    g_ring = NULL;
    atomic_store_explicit(&g_ring_capacity_frames, 0, memory_order_release);
}

int audio_backend_init(int freq, int blocksize, int channels,
                       int *out_freq, int *out_blocksize) {
    (void)out_blocksize;
    teardown_stream();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
    atomic_store_explicit(&g_drop_log_count, 0, memory_order_relaxed);
    atomic_store_explicit(&g_xrun_log_count, 0, memory_order_relaxed);
    atomic_store_explicit(&g_callback_log_count, 0, memory_order_relaxed);

    g_channels = channels > 1 ? 2 : 1;
    g_rate = freq > 0 ? freq : 48000;

    AAudioStreamBuilder *builder = NULL;
    if (AAudio_createStreamBuilder(&builder) != AAUDIO_OK || builder == NULL) {
        LOGE("AAudio builder creation failed");
        return 1;
    }

    const int requested_rate = g_rate;
    int32_t requested_capacity = requested_rate * 240 / 1000;
    if (requested_capacity < 8192) requested_capacity = 8192;

    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSampleRate(builder, requested_rate);
    AAudioStreamBuilder_setChannelCount(builder, g_channels);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_NONE);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setBufferCapacityInFrames(builder, requested_capacity);
    AAudioStreamBuilder_setFramesPerDataCallback(builder, 512);
    AAudioStreamBuilder_setDataCallback(builder, audio_data_callback, NULL);

    aaudio_result_t open_result = AAudioStreamBuilder_openStream(builder, &g_stream);
    AAudioStreamBuilder_delete(builder);
    if (open_result != AAUDIO_OK || g_stream == NULL) {
        LOGE("AAudio stream open failed: %s", AAudio_convertResultToText(open_result));
        return 1;
    }

    g_channels = AAudioStream_getChannelCount(g_stream);
    g_rate = AAudioStream_getSampleRate(g_stream);
    if (out_freq != NULL) *out_freq = g_rate;

    const int32_t capacity = AAudioStream_getBufferCapacityInFrames(g_stream);
    int32_t burst = AAudioStream_getFramesPerBurst(g_stream);
    if (burst < 1) burst = 1;
    int32_t stream_rate = g_rate;
    if (stream_rate < 8000) stream_rate = 8000;
    int32_t target_buffer = stream_rate * 120 / 1000;
    if (target_buffer < burst * 8) target_buffer = burst * 8;
    if (blocksize > 0) {
        if (blocksize > target_buffer) target_buffer = blocksize;
    }
    if (capacity > 0 && target_buffer > capacity) target_buffer = capacity;
    AAudioStream_setBufferSizeInFrames(g_stream, target_buffer);

    int32_t ring_capacity = stream_rate * AUDIO_RING_MILLIS / 1000;
    if (ring_capacity < burst * 16) ring_capacity = burst * 16;
    if (ring_capacity < 8192) ring_capacity = 8192;

    g_ring = calloc((size_t)ring_capacity * (size_t)g_channels, sizeof(int16_t));
    if (g_ring == NULL) {
        LOGE("ring buffer allocation failed");
        AAudioStream_close(g_stream);
        g_stream = NULL;
        return 1;
    }
    atomic_store_explicit(&g_ring_capacity_frames, ring_capacity, memory_order_release);
    int32_t prebuffer = stream_rate * AUDIO_PREBUFFER_MILLIS / 1000;
    if (prebuffer < 2048) prebuffer = 2048;
    atomic_store_explicit(&g_prebuffer_frames, prebuffer, memory_order_release);
    ring_reset();

    aaudio_result_t start_result = AAudioStream_requestStart(g_stream);
    if (start_result != AAUDIO_OK) {
        LOGE("AAudio stream start failed: %s", AAudio_convertResultToText(start_result));
        AAudioStream_close(g_stream);
        g_stream = NULL;
        free(g_ring);
        g_ring = NULL;
        atomic_store_explicit(&g_ring_capacity_frames, 0, memory_order_release);
        return 1;
    }

    LOGI("AAudio opened rate=%d channels=%d capacity=%d burst=%d ring=%d",
         g_rate, g_channels, capacity, burst, ring_capacity);
    return 0;
}

void audio_backend_write(const int16_t *samples, int frames) {
    if (samples == NULL || frames <= 0 || g_channels <= 0 || g_stream == NULL) return;
    if (frames > 0) {
        ring_push(samples, frames);
    }

    const size_t nr = (size_t)frames * (size_t)g_channels;
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
    teardown_stream();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
}

int audio_backend_suspend(void) {
    if (g_stream != NULL) {
        AAudioStream_requestPause(g_stream);
    }
    ring_reset();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
    return 0;
}

int audio_backend_resume(void) {
    ring_reset();
    if (g_stream != NULL) {
        AAudioStream_requestFlush(g_stream);
        AAudioStream_requestStart(g_stream);
    }
    return 0;
}

int32_t audio_backend_get_level(void) {
    return atomic_load_explicit(&g_audio_level, memory_order_relaxed);
}