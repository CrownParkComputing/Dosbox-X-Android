# Native core build

The emulator is not written here. `libdosboxcore` is a thin plain-C bridge in
`native/dosbox_core/bridge/` linked against a **DOSBox-X** build.

## Status

**The bridge is implemented** (`bridge/dosbox_bridge.h` + `dosbox_bridge.cpp`,
~1000 lines): the full C ABI for init/start/stop, the framebuffer, keyboard /
mouse / joystick input, config reflection and save-states. As of 2026-08-19
the core is **built and ABI-verified on all three platforms**:

- **Linux** — `linux/build/libdosboxcore.so`, boot-tested headlessly by
  `check-core.sh` (renders real frames through the bridge).
- **Android** — `jniLibs/arm64-v8a/` and `jniLibs/x86_64/`, both with the
  AAudio backend; device runtime still unverified.
- **iOS** — `ios/build/out/libdosboxcore` (arm64 Mach-O, CoreAudio backend);
  packaged as `libdosboxcore.framework` into the IPA by
  `tools/fix-ipa-native-assets.sh`. Requires `~/dosbox-x-src` (a clean
  DOSBox-X checkout) for the container to clone.

The Flutter app dlopens the real core when the artifact is present and falls
back to `StubDosboxCore` (with a banner) when it is not — that is a runtime
fallback, not a Dart-side switch.

One problem remains open before a real device build is useful: **clean
shutdown** (upstream has no teardown path). Audio is implemented (see below).

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

1. **Audio.** (Implemented.) `bridge/audio_backend*.{c,m}` provides a platform
   audio backend that replaces SDL's audio output with AAudio (Android),
   CoreAudio (iOS) and ALSA (Linux), mirroring ViceMultiplatform's ring-buffer
   / prebuffer design. It is wired into the mixer via weak-symbol hooks in
   `apply-bridge-hook.py`, so a plain dosbox-x build is unchanged; the mixer
   hands freshly-mixed samples to `audio_backend_write()` instead of
   `SDL_OpenAudioDevice`'s callback. `dosbox_core_get_audio_level()` now
   reports the backend's live output peak. The Android build links
   `audio_backend_android.o` with `-laaudio` and has been link-verified. The
   iOS build compiles `audio_backend_ios.m` into the dylib (the bridge calls
   `audio_backend_get_level()` directly, so the link fails without it) and
   has been link-verified. The Linux backend compiles clean headlessly and
   can capture PCM to a WAV via `DOSBOX_AUDIO_WAV_CAPTURE` for verification.
   Not yet runtime-verified on a device.

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
                audio_backend.h + audio_backend_android.c / _linux.c / _ios.m
                                    <- AAudio / ALSA / CoreAudio backends (implemented)
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
