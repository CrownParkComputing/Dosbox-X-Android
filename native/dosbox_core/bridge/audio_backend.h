/*
 * audio_backend.h - Sound backend interface for the DOSBox-X offscreen bridge.
 *
 * DOSBox-X's mixer already renders audio on its own timer (the single
 * producer thread, via MIXER_MixData running on the mainloop). This interface
 * is the substitution for SDL's audio OUTPUT: instead of handing the mixed
 * samples to SDL_OpenAudioDevice's driver (which on Android needs the
 * org.libsdl.app Java glue a Flutter host does not have), the mixer pushes
 * them here and the backend drains a ring buffer into the platform audio
 * device (AAudio / CoreAudio / ALSA).
 *
 * The shape mirrors ViceMultiplatform's bridge/audio_backend*.c (ring buffer
 * + 80ms prebuffer gate + ramp-to-zero underrun fill), but the init signature
 * is DOSBox-X's SDL_AudioSpec-shaped negotiation rather than VICE's
 * speed/fragsize/fragnr form.
 *
 * Not thread-safe to call from multiple producer threads; DOSBox-X only ever
 * calls audio_backend_write() from its single mixer/mainloop thread.
 */
#ifndef DOSBOX_MULTIPLATFORM_AUDIO_BACKEND_H
#define DOSBOX_MULTIPLATFORM_AUDIO_BACKEND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Open the platform audio device and start the background consumer thread.
 *
 *   freq       requested sample rate
 *   blocksize  the mixer's blocksize hint (samples per SDL audio buffer)
 *   channels   requested channel count (DOSBox-X asks for 2)
 *
 * On success the backend writes the actually-obtained rate and a sensible
 * block size back through out_freq/out_blocksize and returns 0. On failure it
 * returns non-zero and the caller falls back to "nosound" mode, exactly as it
 * does when SDL_OpenAudioDevice fails today.
 */
int audio_backend_init(int freq, int blocksize, int channels,
                       int *out_freq, int *out_blocksize);

/*
 * Push `frames` frames of interleaved 16-bit stereo (or mono) PCM into the
 * ring buffer. Called by the mixer's render thread; the backend's own device
 * callback drains it on the audio device's clock.
 */
void audio_backend_write(const int16_t *samples, int frames);

/* Release the device and free the ring. Also silences the level meter. */
void audio_backend_close(void);

/* Stop/start output without tearing down the device. Both reset the ring and
 * zero the level meter (see the suspend() reset rationale in Vice's backend:
 * without it the meter would freeze at its last non-zero peak). */
int audio_backend_suspend(void);
int audio_backend_resume(void);

/* Smoothed 0..100 output peak, computed from real PCM on every write. */
int32_t audio_backend_get_level(void);

#ifdef __cplusplus
}
#endif

#endif /* DOSBOX_MULTIPLATFORM_AUDIO_BACKEND_H */