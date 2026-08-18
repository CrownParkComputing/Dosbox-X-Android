# Native core build

The emulator is not written here. `libdosboxcore` is a thin plain-C bridge in
`native/dosbox_core/bridge/` linked against a **DOSBox-X** build.

## Status

**The bridge is not implemented yet.** What exists today is
`bridge/dosbox_bridge.h` -- the C ABI contract -- and the whole Flutter app
written against it. Until the bridge lands, the app loads
`StubDosboxCore` instead and says so in a banner across the top of the window.
That is a deliberate ordering: the header is the interface both sides have to
agree on, and it is much cheaper to change before either side is built.

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

3. **A dummy SDL window.** `OUTPUT_GAMELINK_SetSize` still calls
   `GFX_SetSDLWindowMode` and `SDL_GetWindowSurface` to keep a window around
   for the menu bar. Inside a Flutter app there is no window to create, so the
   bridge's output needs those calls removed and `SDL_VIDEODRIVER=dummy` set.

4. **Zero-copy frames.** `FramebufferView` polls, copies and calls
   `decodeImageFromPixels`, allocating a texture per frame. The real answer is
   a Flutter `Texture` backed by an external GL/Metal texture the bridge writes
   into. That needs per-platform context sharing and is deliberately deferred.

## Build layout (planned)

```
native/dosbox_core/
  bridge/       dosbox_bridge.h  <- exists; the ABI contract
                dosbox_bridge.c  <- the SCREEN_FLUTTER output + mailboxes
                audio_backend_android.c / _linux.c / _ios.c
  android/      CMakeLists.txt + build.sh -> jniLibs/<abi>/libdosboxcore.so
  linux/        CMakeLists.txt          -> build/libdosboxcore.so
  ios/          static lib per arch, packaged as an .xcframework
```

As in ViceMultiplatform, the bridge links against a **pre-built** DOSBox-X
object tree rather than vendoring or rebuilding one. That tree is large,
machine-specific and not redistributable, so **CI cannot build the native
core** -- CI can only prove the Dart layer compiles and the tests pass.

## Reference material in the old repo

The Java app at `~/StudioProjects/Dosbox-X-Android` carries seven patches under
`native/patches/` that are still relevant, because they fix Android build and
platform problems rather than UI ones:

- `0001-android-configure-target.patch` -- `*-*-android*` case in configure.ac;
  bionic has no `librt`.
- `0002-android-sdl1-cdrom-include.patch` -- `<linux/cdrom.h>` on Android.
- `0003-android-sdlmain.patch` -- suppresses the tinyfd folder prompt that
  hangs, and stops SDL_VIDEODRIVER being forced to x11.
- `0007-android-native-config-gui.patch` -- the config reflection JNI. This is
  the direct ancestor of `dosbox_core_config_*` in the header; port the C
  logic and drop the JNI wrapper.

Patches `0004`-`0006` are about SDL2 GPU scaling to an Android window surface
and are **obsolete here**: there is no SDL window, and scaling is Flutter's job.
