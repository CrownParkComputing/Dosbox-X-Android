# DOSBox-X Multiplatform

A Flutter front end for the [DOSBox-X](https://github.com/joncampbell123/dosbox-x)
emulator, targeting Android, iOS and Linux. Sibling project to
ViceMultiplatform, and the successor to the Java/SDL `Dosbox-X-Android` app.

This repository contains the front end and a plain-C bridge. It does not contain
an emulator: DOSBox-X does all the actual work.

## State

The Flutter app is complete and tested against a **stub core**. The native
bridge (`native/dosbox_core/bridge/dosbox_bridge.{h,cpp}`, ~1000 lines) is
implemented — the full C ABI for init/start/stop, the framebuffer, keyboard /
mouse / joystick input, config reflection and save-states — but it has not yet
been compiled and linked against a real DOSBox-X object tree, so nothing is
emulated yet and the app still loads `StubDosboxCore` (and says so in a banner).
Audio and clean shutdown remain open.

- `docs/NATIVE_BUILD.md` -- how the native core is built, and the problems left
  to solve (audio, shutdown, zero-copy frames).
- `docs/MIGRATION.md` -- what moved over from the Java app, the parity
  checklist, and the per-game compatibility knowledge that must not be lost.
- `docs/PLATFORM_STATUS.md` -- per-platform core bundling, platform-specific
  code, and the divergences to track.

## Layout

```
docs/                       design and build notes
native/dosbox_core/
  bridge/dosbox_bridge.h    the C ABI contract; read this first
flutter_app/
  lib/ffi/                  bindings, the DosboxCore interface, the stub core
  lib/data/                 library entries, SDL scancode catalogue
  lib/services/             config generation, scanning, prefs, storage, input
  lib/screens/              workbench shell, library, emulator, settings
  lib/widgets/              framebuffer view, sidebar, on-screen controls
  test/                     runs with no native core and no game files
```

## Developing

Flutter is not on `PATH` on this machine; use the checkout directly.

```bash
cd flutter_app
/home/jon/development/flutter/bin/flutter pub get
/home/jon/development/flutter/bin/flutter analyze lib test
/home/jon/development/flutter/bin/flutter test
/home/jon/development/flutter/bin/flutter run -d linux
```

The app falls back to `StubDosboxCore` whenever `libdosboxcore` cannot be
loaded, which is the normal state while working on the UI. The stub draws an
animated test pattern at 320x200 with a 1.2 pixel aspect, so aspect handling and
stale-frame bugs are visible rather than hidden.

## Licensing

DOSBox-X is GPLv2. Anything linked against its objects -- which includes the
bridge, and therefore any shipped build -- inherits that. Bear this in mind
before adding dependencies to the Flutter side.
