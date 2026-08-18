# Platform Status

One Flutter front end over the DOSBox-X core, on Android, iOS and Linux. This
page records, per platform, how the native core is bundled, what code is
platform-specific, and where the three builds diverge — so a change that
touches one platform is visible as a difference against the other two.

> Last updated: 2026-08-18. Re-check after the native core is wired up; the
> build scripts exist but a shipped, core-backed build has not been cut yet.

## Shared across all three platforms

Everything below is compiled/interpreted identically on Android, iOS and Linux.

- `flutter_app/lib/` — the whole app: 37 Dart files across
  `screens/`, `services/`, `widgets/`, `theme/`, `data/`, `ffi/`. All UI and
  all GUI/layout code lives here; there is no per-platform layout.
- `native/dosbox_core/bridge/dosbox_bridge.{h,cpp}` — the C ABI. One contract,
  implemented once, linked against DOSBox-X on every platform.
- `pubspec.yaml` — one dependency set: `ffi`, `path`, `file_picker`,
  `shared_preferences`, `path_provider`, `gamepads`, `archive`.

## Per-platform

### Android

- **Core bundling** — `libdosboxcore.so` ships in
  `flutter_app/android/app/src/main/jniLibs/<abi>/` and is loaded by bare name
  (`DynamicLibrary.open('libdosboxcore.so')`). Built by
  `native/dosbox_core/android/build.sh` (applies 9 patches, then cross-builds
  per ABI: arm64-v8a, x86_64).
- **Platform-specific code**:
  - `MainActivity.kt` — gamepad hookup (`GamepadsCompatibleActivity`) +
    manual SDL JNI init + storage/permission handling.
  - `AppRestartActivity.kt` — process restart for settings changes.
  - `org/libsdl/app/*.java` (11 files) — SDL2's Android Java glue
    (`SDL`, `SDLActivity`, `SDLAudioManager`, `HIDDevice*`, controllers).
  - `native/dosbox_core/android/patches/` — 9 DOSBox-X source patches.
- **Divergences** — the heaviest platform. SDL2's Android backend assumes its
  host is `SDLActivity`, but ours is a `FlutterActivity`, so SDL JNI is
  initialised by hand and the `org.libsdl.app.*` stubs exist purely to satisfy
  `JNI_OnLoad`'s `FindClass`.

### iOS

- **Core bundling** — the bridge is shipped as `libdosboxcore.framework`
  inside `Runner.app/Frameworks/`, dlopen'd by path (`DynamicLibrary.open`).
  Built by `native/dosbox_core/ios/build-ios.sh` (Docker cross-build).
- **Platform-specific code**:
  - `AppDelegate.swift`, `SceneDelegate.swift` — standard Flutter iOS.
  - `Runner-Bridging-Header.h` — just `GeneratedPluginRegistrant.h`.
  - `native/dosbox_core/ios/{apply-ios-configure,apply-ios-source}.py`.
- **Divergences** — framework (not loose dylib) because iOS code-signs every
  nested Mach-O in `Frameworks/`; no SDL Java glue or JNI anywhere.

### Linux

- **Core bundling** — `libdosboxcore.so` next to the executable; in a dev
  checkout the path is derived from the repo root
  (`native/dosbox_core/linux/build/`). Built by
  `native/dosbox_core/linux/build.sh` (or `build-core-pic.sh`).
- **Platform-specific code** — `my_application.cc` (standard Flutter/GTK);
  nothing else.
- **Divergences** — the reference/dev platform. Gamepads work through the
  desktop `gamepads` plugin path (no activity subclass needed).

## Differences to track

| Concern | Android | iOS | Linux |
|---|---|---|---|
| Core load | bare-name from jniLibs | explicit path into Frameworks/ | path next to executable |
| Core artifact | `.so` per ABI | `.framework` | `.so` |
| Audio | SDL2 Android backend (needs SDL JNI) | CoreAudio | ALSA |
| Input / gamepad | `GamepadsCompatibleActivity` | (standard) | desktop plugin |
| Storage / permissions | runtime permission + SAF | sandbox | plain filesystem |
| Native patches | 9 | configure/source scripts | bridge-hook only |
| Build host | NDK cross-compile | Docker cross-build | native |

## Review notes (open items)

1. **Docs were stale, now fixed.** `README.md` and `docs/NATIVE_BUILD.md`
   previously said the bridge was "not implemented"; it is implemented
   (`dosbox_bridge.cpp`, ~1000 lines) but not yet compiled against a real
   DOSBox-X tree. Both are corrected, and the audio/shutdown gaps are called
   out as the remaining work.
2. **Android is by far the most customised platform** — the SDL Java glue plus
   the manual SDL-JNI bootstrap plus 9 patches is real, load-bearing complexity
   that iOS and Linux simply do not have. Worth a second look once the core is
   running: the `org.libsdl.app.*` stubs and the hand-rolled `SDL.setupJNI()`
   path are the highest-risk parts and should not grow.
3. **GUI/layouts are fully shared** — confirmed nothing in `android/res`,
   `ios/*.storyboard`, or `linux/` carries layout; all screens and widgets are
   in `lib/`.
4. **Core is not yet bundled in a shipped build** — the per-platform build
   scripts exist and the bridge is implemented, but a core-backed APK/IPA/App
   has not been produced. Each platform's "core bundled" row above is the
   *intended* mechanism, not a shipped artifact.
