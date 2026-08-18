# Native core build

The emulator is not written here. `libdosboxcore` is a thin plain-C bridge in
`native/dosbox_core/bridge/` linked against a **DOSBox-X** build.

## Status

**The bridge is implemented** (`bridge/dosbox_bridge.h` + `dosbox_bridge.cpp`,
~1000 lines): the full C ABI for init/start/stop, the framebuffer, keyboard /
mouse / joystick input, config reflection and save-states. It has not yet been
compiled and linked against a real DOSBox-X object tree, so the app still loads
`StubDosboxCore` and says so in a banner across the top of the window. Two
problems remain open before a real build is useful: audio (no backend yet) and
clean shutdown (upstream has no teardown path); see below.

## Why this is feasible: the Game Link output

DOSBox-X already renders offscreen. The `SCREEN_GAMELINK` output backend
(`src/output/output_gamelink.cpp`, `src/gamelink/`), built upstream so external
tools like Grid Cartographer can drive a DOS session, does exactly what this
project needs:

| What we need | What Game Link already does |
| --- | --- |
| A framebuffer instead of a window | `OUTPUT_GAMELINK_StartUpdate()` hands `render.cpp` a malloc'd 32bpp buffer (`sdl.gamelink.framebuf`) rather than an SDL surface |
| A way to publish finished frames | `OUTPUT_GAMELINK_Transfer()` |
| Injected keyboard and mouse | `OUTPUT_GAMELINK_InputEvent()` feeds `MAPPER_CheckEvent` / `Mouse_*` from an external client's state |
| SDL not owning input | `sdlmain.cpp` is already full of `if (sdl.desktop.type == SCREEN_GAMELINK) break;` guards |
| A known pixel format | `GFX_GetRGB`'s `SCREEN_GAMELINK` case is fixed `0xAARRGGBB` |

So the bridge is not a new renderer. It is a `SCREEN_FLUTTER` output modelled on
`SCREEN_GAMELINK` with the shared-memory mmap replaced by an in-process buffer
handed out through `dosbox_core_get_framebuffer()`.

`0xAARRGGBB` little-endian is `B,G,R,A` in memory order, which is exactly
Flutter's `ui.PixelFormat.bgra8888` -- so frames reach the screen with no
conversion pass. See `lib/widgets/framebuffer_view.dart`.

## Known problems to solve, in order

1. **Audio.** DOSBox-X's mixer calls `SDL_OpenAudioDevice` directly
   (`src/hardware/mixer.cpp`). SDL2's Android audio backend needs
   `org.libsdl.app.SDLAudioManager` and a live SDL JNI environment, neither of
   which exists inside a Flutter host. The decided approach is a mixer output
   feeding AAudio on Android, CoreAudio on iOS and ALSA on Linux, mirroring
   ViceMultiplatform's `bridge/audio_backend*.c`. Until then a session is
   silent.

2. **Shutdown.** Upstream DOSBox-X has no complete teardown path. The Java
   Android app this replaces sidestepped it by running the emulator in a
   separate `:emu` process and killing it; Flutter is single-process, so that
   trick is unavailable. `dosbox_core_stop()` therefore returns `DOSBOX_ERR`
   and the app is honest about it -- launching a second title reports that a
   restart is needed. Fixing this properly means real teardown in the core.

3. **A dummy SDL window.** (Addressed.) The bridge sets
   `SDL_VIDEODRIVER=dummy` before init (`dosbox_bridge.cpp`), and the
   window-creation calls in the output path are removed by the bridge hook, so
   there is no SDL window to fight over.

4. **Zero-copy frames.** `FramebufferView` polls, copies and calls
   `decodeImageFromPixels`, allocating a texture per frame. The real answer is
   a Flutter `Texture` backed by an external GL/Metal texture the bridge writes
   into. That needs per-platform context sharing and is deliberately deferred.

## Build layout

```
native/dosbox_core/
  bridge/       dosbox_bridge.h     <- the ABI contract
                dosbox_bridge.cpp   <- the SCREEN_FLUTTER output + mailboxes (implemented)
                audio_backend_android.c / _linux.c / _ios.c   <- not written yet
  android/      build.sh + patches/ -> flutter_app/.../jniLibs/<abi>/libdosboxcore.so
  linux/        build.sh / build-core-pic.sh -> build/libdosboxcore.so
  ios/          build-ios.sh (Docker) -> libdosboxcore.framework
```

As in ViceMultiplatform, the bridge links against a **pre-built** DOSBox-X
object tree rather than vendoring or rebuilding one. That tree is large,
machine-specific and not redistributable, so **CI cannot build the native
core** -- CI can only prove the Dart layer compiles and the tests pass.

## The Android patches

The nine DOSBox-X source patches that make the Android build work now live in
this repo at `native/dosbox_core/android/patches/`, applied by
`native/dosbox_core/android/build.sh`. They are documented per-file in
`patches/README.md` there; the short version:

- `0001` configure target for `*-*-android*` (no `librt`); `0002` SDL1 CD-ROM
  include; `0003` suppress the tinyfd prompt and the forced x11 driver;
  `0004`-`0006` render aspect + GPU content scaling.
- `0007` the native config GUI (ancestor of `dosbox_core_config_*`); `0008`
  Game Link's `shm_open` replaced (bionic has no shared memory); `0009` expose
  the synthetic joystick before DOS startup.
