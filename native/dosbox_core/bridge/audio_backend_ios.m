/*
 * audio_backend_ios.m - CoreAudio (AudioQueue) sound backend for the DOSBox-X
 * offscreen bridge on iOS. Satisfies audio_backend.h.
 *
 * Mirrors ViceMultiplatform's bridge/audio_backend_ios.m, adapted to this
 * bridge's init signature. The ring buffer, the 80ms prebuffer gate and the
 * ramp-to-zero underrun fill are identical across platforms; only the device
 * layer differs (AudioQueue here instead of ALSA or AAudioStream).
 *
 * Objective-C rather than plain C purely for AVAudioSession: without setting a
 * category the app gets SoloAmbient, which the hardware mute switch silences --
 * an emulator that goes quiet when the ringer switch is flipped is a bug.
 */
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_backend.h"

#define LOG_TAG "[DosboxAudio] "
#define LOGI(...) do { fprintf(stderr, LOG_TAG "INFO: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define LOGW(...) do { fprintf(stderr, LOG_TAG "WARN: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define LOGE(...) do { fprintf(stderr, LOG_TAG "ERROR: " __VA_ARGS__); fputc('\n', stderr); } while (0)

#define AUDIO_RING_MILLIS 500
#define AUDIO_PREBUFFER_MILLIS 80

/* AudioQueue is a push model: it hands back a buffer to refill and we re-enqueue
 * it. Three buffers of 512 frames keeps latency near the AAudio backend's
 * callback size while leaving slack for scheduling jitter. */
#define AUDIO_QUEUE_BUFFERS 3
#define AUDIO_QUEUE_FRAMES_PER_BUFFER 512

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

static AudioQueueRef g_queue = NULL;
static AudioQueueBufferRef g_buffers[AUDIO_QUEUE_BUFFERS];
static atomic_bool g_running = false;

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

static void fill_output(int16_t *output, int32_t num_frames) {
    const int channels = g_channels;
    const int32_t capacity = atomic_load_explicit(&g_ring_capacity_frames, memory_order_acquire);
    if (output == NULL || num_frames <= 0 || channels <= 0 || capacity <= 0 || g_ring == NULL) {
        return;
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
        return;
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
            LOGW("callback underrun read=%d requested=%d available=%d",
                 frames_to_read, num_frames, available);
        }
    }

    atomic_store_explicit(&g_read_frame, read + (uint64_t)frames_to_read, memory_order_release);
}

static void audio_queue_callback(void *user_data, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void)user_data;
    const int channels = g_channels > 0 ? g_channels : 2;
    const UInt32 frame_bytes = (UInt32)(channels * (int)sizeof(int16_t));
    UInt32 frames = buffer->mAudioDataBytesCapacity / frame_bytes;

    memset(buffer->mAudioData, 0, buffer->mAudioDataBytesCapacity);
    fill_output((int16_t *)buffer->mAudioData, (int32_t)frames);
    buffer->mAudioDataByteSize = frames * frame_bytes;

    if (atomic_load_explicit(&g_running, memory_order_acquire)) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
}

static void teardown_queue(void) {
    atomic_store_explicit(&g_running, false, memory_order_release);
    if (g_queue != NULL) {
        AudioQueueStop(g_queue, true);
        AudioQueueDispose(g_queue, true);
        g_queue = NULL;
    }
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        g_buffers[i] = NULL;
    }
    free(g_ring);
    g_ring = NULL;
    atomic_store_explicit(&g_ring_capacity_frames, 0, memory_order_release);
    ring_reset();
}

static void configure_audio_session(void) {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        LOGW("could not set audio session category: %s",
             error ? error.localizedDescription.UTF8String : "unknown error");
    }
    error = nil;
    if (![session setActive:YES error:&error]) {
        LOGW("could not activate audio session: %s",
             error ? error.localizedDescription.UTF8String : "unknown error");
    }
}

int audio_backend_init(int freq, int blocksize, int channels,
                       int *out_freq, int *out_blocksize) {
    (void)blocksize;
    teardown_queue();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
    atomic_store_explicit(&g_drop_log_count, 0, memory_order_relaxed);
    atomic_store_explicit(&g_xrun_log_count, 0, memory_order_relaxed);
    atomic_store_explicit(&g_callback_log_count, 0, memory_order_relaxed);

    configure_audio_session();

    g_channels = channels > 1 ? 2 : 1;
    g_rate = freq > 0 ? freq : 48000;
    if (g_rate < 8000) g_rate = 8000;

    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = (Float64)g_rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 16;
    format.mChannelsPerFrame = (UInt32)g_channels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = (UInt32)(g_channels * (int)sizeof(int16_t));
    format.mBytesPerPacket = format.mBytesPerFrame;

    OSStatus status = AudioQueueNewOutput(&format, audio_queue_callback, NULL,
                                          NULL, NULL, 0, &g_queue);
    if (status != noErr || g_queue == NULL) {
        LOGE("AudioQueueNewOutput failed: %d", (int)status);
        return 1;
    }

    if (out_freq != NULL) *out_freq = g_rate;
    if (out_blocksize != NULL) *out_blocksize = AUDIO_QUEUE_FRAMES_PER_BUFFER;

    int32_t ring_capacity = g_rate * AUDIO_RING_MILLIS / 1000;
    if (blocksize > 0 && blocksize * 2 > ring_capacity) ring_capacity = blocksize * 2;
    if (ring_capacity < 8192) ring_capacity = 8192;

    g_ring = (int16_t *)calloc((size_t)ring_capacity * (size_t)g_channels, sizeof(int16_t));
    if (g_ring == NULL) {
        LOGE("could not allocate %d frame ring buffer", ring_capacity);
        teardown_queue();
        return 1;
    }
    atomic_store_explicit(&g_ring_capacity_frames, ring_capacity, memory_order_release);
    atomic_store_explicit(&g_prebuffer_frames, g_rate * AUDIO_PREBUFFER_MILLIS / 1000,
                          memory_order_release);
    ring_reset();

    const UInt32 buffer_bytes =
            (UInt32)(AUDIO_QUEUE_FRAMES_PER_BUFFER * g_channels * (int)sizeof(int16_t));
    atomic_store_explicit(&g_running, true, memory_order_release);
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(g_queue, buffer_bytes, &g_buffers[i]);
        if (status != noErr || g_buffers[i] == NULL) {
            LOGE("AudioQueueAllocateBuffer failed: %d", (int)status);
            teardown_queue();
            return 1;
        }
        memset(g_buffers[i]->mAudioData, 0, buffer_bytes);
        g_buffers[i]->mAudioDataByteSize = buffer_bytes;
        AudioQueueEnqueueBuffer(g_queue, g_buffers[i], 0, NULL);
    }

    status = AudioQueueStart(g_queue, NULL);
    if (status != noErr) {
        LOGE("AudioQueueStart failed: %d", (int)status);
        teardown_queue();
        return 1;
    }

    LOGI("started: rate=%d channels=%d ring=%d frames prebuffer=%d frames",
         g_rate, g_channels, ring_capacity,
         atomic_load_explicit(&g_prebuffer_frames, memory_order_relaxed));
    return 0;
}

void audio_backend_write(const int16_t *samples, int frames) {
    if (samples == NULL || frames <= 0 || g_channels <= 0 || g_queue == NULL) return;
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
    teardown_queue();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
}

int audio_backend_suspend(void) {
    if (g_queue != NULL) {
        AudioQueuePause(g_queue);
    }
    ring_reset();
    atomic_store_explicit(&g_audio_level, 0, memory_order_relaxed);
    return 0;
}

int audio_backend_resume(void) {
    ring_reset();
    if (g_queue != NULL) {
        AudioQueueFlush(g_queue);
        AudioQueueStart(g_queue, NULL);
    }
    return 0;
}

int32_t audio_backend_get_level(void) {
    return atomic_load_explicit(&g_audio_level, memory_order_relaxed);
}