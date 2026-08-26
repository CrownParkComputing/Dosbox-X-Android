#!/usr/bin/env python3
"""Apply the bridge's two edits to a DOSBox-X checkout.

Deliberately anchored on text rather than shipped as a unified diff: the diff
would carry line numbers that go stale every time the upstream tree moves, and
fail with a rejected hunk rather than a useful message. Both edits are
idempotent, so re-running after an upstream pull is safe.

1. output_gamelink.cpp -- OUTPUT_GAMELINK_Transfer() is where the Game Link
   output publishes a finished frame, and it already has everything the bridge
   needs in scope: the 32bpp framebuffer, the clip dimensions and
   render.src.ratio. The hook goes there and nowhere else. It calls a weak
   symbol, so a plain dosbox-x build (which does not link the bridge) resolves
   it to null, skips the call, and behaves exactly as before.

2. sdlmain.cpp -- expose main() under a second name. The bridge runs the engine
   on a background thread, and calling main() directly from C++ is not
   something the standard permits.

3. sdlmain.cpp -- pump the bridge from GFX_Events(). Normal_Loop calls
   GFX_Events() every tick whether or not anything was drawn, which is exactly
   the property the frame hook lacks: DOSBox-X publishes a frame only when the
   picture changes, so a booted guest OS sitting on a still desktop stopped
   reaching the hook at all and the app's input/pause/quit queue went dead.
   Applied as its own edit with its own marker so a tree already patched for
   (2) still picks it up.
"""
import os
import sys

TREE = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/dosbox-x-pic")

HOOK_DECL = '''
/* Implemented by the DosboxMultiplatform bridge when it is linked in. Weak so
 * a plain dosbox-x build resolves it to null and skips the call below. */
extern "C" void DOSBOX_BRIDGE_PublishFrame(const uint32_t *pixels, int32_t width,
                                           int32_t height, int32_t pitch_bytes,
                                           double ratio) __attribute__((weak));
'''

HOOK_CALL = '''    if (DOSBOX_BRIDGE_PublishFrame) {
        DOSBOX_BRIDGE_PublishFrame(
            (const uint32_t*)sdl.gamelink.framebuf,
            (int32_t)(sdl.clip.w + 2 * sdl.clip.x),
            (int32_t)(sdl.clip.h + 2 * sdl.clip.y),
            (int32_t)sdl.gamelink.pitch,
            render.src.ratio);
    }

'''

PUMP_DECL = '''
/* Implemented by the DosboxMultiplatform bridge when it is linked in. Weak so
 * a plain dosbox-x build resolves it to null and skips the call below. */
extern "C" void DOSBOX_BRIDGE_Pump(void) __attribute__((weak));
'''

PUMP_CALL = '''    /* The bridge's tick-rate pump. GFX_Events() is where a real user's input
     * arrives, and Normal_Loop calls it whether or not a frame was drawn --
     * which is why the app's queue is drained here and not only when the
     * picture changes. */
    if (DOSBOX_BRIDGE_Pump) DOSBOX_BRIDGE_Pump();

'''

MAIN_ALIAS = '''

/* Entry point for the DosboxMultiplatform bridge, which runs the engine on a
 * background thread. Calling main() directly from C++ is not permitted by the
 * standard, so it gets its own name. */
extern "C" int dosbox_x_main(int argc, char *argv[]) {
    return main(argc, argv);
}
'''


def edit(path, marker, apply_fn):
    with open(path) as f:
        text = f.read()
    if marker in text:
        print(f"    {os.path.basename(path)}: already patched")
        return
    new = apply_fn(text)
    if new is None:
        sys.exit(f"error: anchor not found in {path} - has upstream moved?")
    with open(path, "w") as f:
        f.write(new)
    print(f"    {os.path.basename(path)}: patched")


def patch_gamelink(text):
    # Upstream dosbox-x-v2026.08.02 dropped the `extern const char* RunningProgram;`
    # line that an earlier version anchored on. `RunningProgramHash` next to it
    # is the stable neighbour and lives in the same translation unit, so the
    # declaration continues to be in scope at the call site below.
    anchor = 'extern uint32_t RunningProgramHash[4];'
    if anchor not in text:
        return None
    text = text.replace(anchor, anchor + "\n" + HOOK_DECL, 1)

    call_anchor = '    GameLink::Out( (uint16_t)sdl.clip.w'
    if call_anchor not in text:
        return None
    return text.replace(call_anchor, HOOK_CALL + call_anchor, 1)


def patch_sdlmain(text):
    return text + MAIN_ALIAS


def patch_sdlmain_pump(text):
    # GFX_Events() opens with CheckMapperKeyboardLayout() and has done for
    # years; anchoring on the pair keeps this from matching a declaration.
    anchor = 'void GFX_Events() {\n    CheckMapperKeyboardLayout();\n'
    if anchor not in text:
        return None
    # The declaration goes at the top of the file rather than beside the call:
    # GFX_Events() is deep in the file and an extern "C" declaration has to be
    # at namespace scope.
    decl_anchor = '#include "sdlmain.h"'
    if decl_anchor not in text:
        return None
    text = text.replace(decl_anchor, decl_anchor + "\n" + PUMP_DECL, 1)
    return text.replace(anchor, anchor + PUMP_CALL, 1)


# --- mixer.cpp ------------------------------------------------------------
#
# DOSBox-X's mixer produces interleaved int32 stereo into mixer.work[] and,
# in its SDL2 path, hands it to SDL_OpenAudioDevice's callback. The bridge
# replaces SDL's audio OUTPUT with the platform backend (AAudio / CoreAudio /
# ALSA) so the core does not depend on SDL's audio driver -- which on Android
# needs org.libs.app.SDLAudioManager and a live JNI env a Flutter host cannot
# provide. Three edits, all weak-symbol-guarded so a plain dosbox-x build is
# byte-for-byte unchanged in behaviour:

MIXER_EXTERNS = '''/* DosboxMultiplatform bridge audio backend. Declared weak at file scope:
 * C++ forbids an extern "C" linkage specification inside a function body, and
 * these must be weak so a plain dosbox-x build (which does not link the
 * backend) resolves them to null and behaves exactly as before. */
extern "C" int audio_backend_init(int, int, int, int *, int *) __attribute__((weak));
extern "C" void audio_backend_write(const int16_t *, int) __attribute__((weak));

'''

MIXER_DECL = '''    spec.samples=(Uint16)mixer.blocksize;

    /* DosboxMultiplatform bridge: substitute the platform audio backend for
     * SDL's audio output. audio_backend_init is declared weak at file scope
     * (above), so dosbox_audio_backend is false in a plain dosbox-x build and
     * the SDL path below runs unchanged. */
    const bool dosbox_audio_backend = (audio_backend_init != NULL);

'''

MIXER_INIT_GUARD = '''#ifdef C_SDL2
    if (!dosbox_audio_backend && SDL_InitSubSystem(SDL_INIT_AUDIO) < 0) {
'''

MIXER_INIT_BRANCH = '''    if (dosbox_audio_backend) {
        int ab_freq = 0, ab_blocksize = 0;
        if (audio_backend_init((int)mixer.freq, (int)mixer.blocksize, spec.channels,
                               &ab_freq, &ab_blocksize) == 0) {
            mixer.freq = (unsigned int)ab_freq;
            if (ab_blocksize > 0) mixer.blocksize = (unsigned int)ab_blocksize;
            TIMER_AddTickHandler(MIXER_Mix);
            if (mixer.sampleaccurate) PIC_AddEvent(MIXER_MixSingle, 1000.0 / mixer.freq);
        } else {
            mixer.nosound = true;
            LOG(LOG_MISC,LOG_DEBUG)("MIXER:Can't open audio backend, running in nosound mode.");
            TIMER_AddTickHandler(MIXER_Mix);
        }
    } else if (mixer.nosound) {
        LOG(LOG_MISC,LOG_DEBUG)("MIXER:No Sound Mode Selected.");
        TIMER_AddTickHandler(MIXER_Mix);
'''

MIXER_PUSH = '''    /* DosboxMultiplatform bridge: hand the freshly-mixed samples to the
     * platform audio backend instead of SDL's callback. converted with
     * mastervol exactly as MIXER_CallBack does. Weak: skipped in a plain
     * dosbox-x build. readpos does not wrap within one MIXER_MixData call --
     * whole <= samples_this_ms.w and MIXER_Mix asserts work_in + that <=
     * MIXER_BUFSIZE -- so the same no-wrap assumption as the capture block
     * below holds. */
    if (audio_backend_write) {
        int32_t volscale1 = (int32_t)(mixer.mastervol[0] * (1 << MIXER_VOLSHIFT));
        int32_t volscale2 = (int32_t)(mixer.mastervol[1] * (1 << MIXER_VOLSHIFT));
        Bitu pending = whole - prev_rendered;
        Bitu readpos = mixer.work_in + prev_rendered;
        while (pending > 0) {
            Bitu chunk = pending > 1024 ? 1024 : pending;
            int16_t convert[1024][2];
            for (Bitu i = 0; i < chunk; i++) {
                convert[i][0] = MIXER_CLIP(((int64_t)mixer.work[readpos][0] * (int64_t)volscale1) >> (MIXER_VOLSHIFT + MIXER_VOLSHIFT));
                convert[i][1] = MIXER_CLIP(((int64_t)mixer.work[readpos][1] * (int64_t)volscale2) >> (MIXER_VOLSHIFT + MIXER_VOLSHIFT));
                readpos++;
            }
            audio_backend_write((const int16_t *)convert, (int)chunk);
            pending -= chunk;
        }
    }

'''


def patch_mixer(text):
    # File-scope weak declarations. Must precede MIXER_MixData (which calls
    # audio_backend_write) as well as MIXER_Init, so anchor on a global near
    # the top of the file rather than on either function.
    scope_anchor = 'unsigned long long mixer_sample_counter = 0;'
    if scope_anchor not in text:
        return None
    text = text.replace(scope_anchor, scope_anchor + '\n' + MIXER_EXTERNS, 1)

    anchor = '    spec.samples=(Uint16)mixer.blocksize;'
    if anchor not in text:
        return None
    text = text.replace(anchor, MIXER_DECL, 1)

    guard = '#ifdef C_SDL2\n    if (SDL_InitSubSystem(SDL_INIT_AUDIO) < 0) {'
    if guard not in text:
        return None
    text = text.replace(guard, MIXER_INIT_GUARD, 1)

    branch = '    if (mixer.nosound) {\n        LOG(LOG_MISC,LOG_DEBUG)("MIXER:No Sound Mode Selected.");\n        TIMER_AddTickHandler(MIXER_Mix);'
    if branch not in text:
        return None
    text = text.replace(branch, MIXER_INIT_BRANCH, 1)

    push = '    if (CaptureState & (CAPTURE_WAVE|CAPTURE_VIDEO)) {'
    if push not in text:
        return None
    text = text.replace(push, MIXER_PUSH + push, 1)

    return text


print(f"==> patching {TREE}")
edit(os.path.join(TREE, "src/output/output_gamelink.cpp"),
     "DOSBOX_BRIDGE_PublishFrame", patch_gamelink)
edit(os.path.join(TREE, "src/gui/sdlmain.cpp"),
     "dosbox_x_main", patch_sdlmain)
edit(os.path.join(TREE, "src/gui/sdlmain.cpp"),
     "DOSBOX_BRIDGE_Pump", patch_sdlmain_pump)
edit(os.path.join(TREE, "src/hardware/mixer.cpp"),
     "dosbox_audio_backend", patch_mixer)
print("==> done")
