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


print(f"==> patching {TREE}")
edit(os.path.join(TREE, "src/output/output_gamelink.cpp"),
     "DOSBOX_BRIDGE_PublishFrame", patch_gamelink)
edit(os.path.join(TREE, "src/gui/sdlmain.cpp"),
     "dosbox_x_main", patch_sdlmain)
print("==> done")
