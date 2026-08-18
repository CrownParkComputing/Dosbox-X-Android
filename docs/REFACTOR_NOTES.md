# Refactor notes — collapse platform code into the shared core

The UI, layout, and game logic are already fully shared (`flutter_app/lib/`,
37 Dart files). The only meaningful platform-specific code left is on Android,
and almost all of it is a *workaround* for two unfinished bridge features, not a
genuine platform divergence. Finish those two features and Android shrinks to
the same near-vanilla shape as iOS and Linux.

## 1. Finish the bridge audio + input backends → delete the SDL Java glue

**The single biggest win.** Today the core links against SDL2's *Android*
backend, which assumes its host activity is `org.libsdl.app.SDLActivity`. Ours
is a `FlutterActivity`, so `MainActivity.setupSdlJni()` (~60 lines) hand-boots
SDL's JNI, and the 11 `org/libsdl/app/*.java` stubs exist only so `JNI_OnLoad`'s
`FindClass` doesn't segfault.

The bridge already renders offscreen via the Game Link output with
`SDL_VIDEODRIVER=dummy` — the same path Linux uses. What keeps Android on the
real SDL backend is **audio** (`SDL_OpenAudioDevice` → `SDLAudioManager`) and
**HID/joystick** (`PLATFORM_hid_init`).

Do what `docs/NATIVE_BUILD.md` already plans: a bridge audio backend per
platform (`audio_backend_android.c` → AAudio, `_ios.c` → CoreAudio, `_linux.c`
→ ALSA) plus a bridge-owned joystick/HID path. Then:

- delete `org/libsdl/app/*.java` (11 files),
- delete `setupSdlJni()` and the `sdlInitialized`/`HIDDeviceManager` state,
- drop patches `0003` (SDL driver forcing), `0005`/`0006` (GPU content scaling —
  Flutter does the scaling), and `0009` (synthetic joystick — the bridge
  exposes it directly),
- the Android core then links SDL in *dummy* mode exactly like Linux.

Net effect: Android's platform-specific code collapses to the gamepad activity
and the storage channel (below), and the "9 patches" line in the status table
drops to ~4.

## 2. Finish shutdown teardown → delete the restart mechanism

`AppRestartActivity.kt` (in the private `:restart` process), the
`app_restart` MethodChannel, and the whole `restartApp()` path exist only
because `dosbox_core_stop()` returns `DOSBOX_ERR` (upstream DOSBox-X has no
teardown). The app relaunches the whole process to "quit" a title.

When teardown is implemented in the core, delete all of it — the restart
channel, the helper activity, and the `:restart` manifest entry. This is
Android-only code that evaporates with the shutdown fix.

## 3. Storage permission — leave as-is

`MainActivity`'s two-method channel (`hasAllFilesAccess` /
`requestAllFilesAccess`) is already the minimal shape: shared Dart
(`permissions_service.dart` / `storage_access.dart`) + a thin platform channel.
It's smaller than pulling in `permission_handler`, and it's genuinely
Android-specific (SAF / MANAGE_EXTERNAL_STORAGE has no iOS/Linux analogue).
No refactor.

## 4. Gamepad — leave as-is

`GamepadsCompatibleActivity` is required by the `gamepads` plugin's Android
implementation; the actual mapping/state lives in shared
`lib/services/gamepad_service.dart`. This is already the correct split.

## 5. (Shared, not platform) zero-copy frames

`FramebufferView` polls + `decodeImageFromPixels` per frame. The real fix is a
Flutter `Texture` backed by the bridge's GL/Metal surface — shared Dart, but it
needs per-platform context sharing. Deferred; note it is the next perf item
after audio, not a platform-divergence problem.

## Summary

| Action | Files removed | Trigger |
|---|---|---|
| Bridge audio + HID backends | 11 `org/libsdl/app/*.java`, ~60 lines Kotlin, 3–5 patches | finish `audio_backend_*.c` + HID |
| Shutdown teardown | `AppRestartActivity.kt`, restart channel | finish `dosbox_core_stop()` |
| (none) | storage + gamepad stay | already minimal |

The north star: **nothing platform-specific should exist that is not either a
plugin's required host hookup or a genuinely OS-only capability (permissions,
sandbox, code-signing).** Today the only violations are the SDL-JNI bootstrap
and the restart hack — both consequences of unfinished bridge work, both
slated to be deleted.
