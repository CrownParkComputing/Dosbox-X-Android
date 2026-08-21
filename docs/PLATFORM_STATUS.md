# Platform Status

One Flutter front end over the DOSBox-X core, on Android, iOS and Linux. This
page records, per platform, how the native core is bundled, what code is
platform-specific, and where the three builds diverge — so a change that
touches one platform is visible as a difference against the other two.

> Last updated: 2026-08-19. The native core is now built and ABI-verified on
> all three platforms (details per platform below); a shipped, core-backed
> APK/IPA/App has still not been cut, and audio is not yet runtime-verified
> on a device.

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
  per ABI). **Built and in place for both declared ABIs**: arm64-v8a
  (2026-08-18) and x86_64 (2026-08-19), both link- and ABI-verified, both
  including the AAudio backend (`libaaudio.so` in NEEDED).
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
  Built by `native/dosbox_core/ios/build-ios.sh` (Docker cross-build from
  `~/dosbox-x-src`, which must exist). **Built 2026-08-19**:
  `ios/build/out/libdosboxcore` is an arm64 Mach-O dylib with the full ABI
  (31 symbols) and the CoreAudio backend linked in; it is packaged into the
  framework at IPA-repack time by `tools/fix-ipa-native-assets.sh`.
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
  **Built 2026-08-19** and runtime-verified headlessly: `check-core.sh` boots
  the core through the bridge and publishes real frames (gamelink 720x400 →
  640x480 framebuffer, frame counter advancing).
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
4. **Cores are built on all three platforms, but no shipped app yet** — the
   artifacts above are real and ABI-verified, but a core-backed APK/IPA/App
   has not been cut, and no device has booted one. Next: `flutter build apk`,
   `tools/deploy-ios.sh` (needs a terminal for the Apple ID 2FA prompt), and
   a packaged Linux bundle.
5. **The shared `~/dosbox-x-pic` tree is single-config** — Android
   reconfigures it in place for the NDK target, so after an Android build the
   tree is no longer host-configured. `build-core-pic.sh` now detects this
   (cross `--host` in `config.status`, or foreign-arch objects on disk) and
   reconfigures + `make clean`s before building for the host. Rule of thumb:
   run `build-core-pic.sh` before `linux/build.sh` whenever the tree was last
   used by Android. iOS is unaffected (it clones its own tree inside the
   container).
