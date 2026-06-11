# DOSBox-X Android

A handheld-friendly Android front-end for [DOSBox-X](https://dosbox-x.com/), built for
playing DOS games and running a Windows 98 guest on devices like the Retroid Pocket.
The native emulator (`libmain.so`, DOSBox-X 2026.06) is bundled; this repo is the
Java/Android launcher and overlay around it.

## What it does

- **On-device game launcher** with two tabs:
  - **MS-DOS** — game folders and disk images (`.iso` / `.cue+bin` / `.img`). Tap to play;
    the launcher auto-picks the right executable, gives each CD game its own persistent
    writable `C:` drive, and copies "pre-installed" CDs onto `C:` so saves survive.
  - **Windows 98** — boots a Win9x hard-disk image, with an in-app **CD changer** and
    library so you can insert / eject / swap discs and create a formatted data drive.
- **On-screen keyboard** — a full, edge-to-edge staggered PC keyboard overlay that
  injects real key events into the emulator.
- **Gamepad support** — per-game keymaps, plus a "joystick mode" that passes the pad
  through to DOS as a real gameport joystick.
- **Trackpad mouse** for Windows guests (relative motion, tap / two-finger / drag).
- **3dfx Voodoo** via the software rasterizer (`voodoo_card=software`) for Glide games.
- **In-app tooling** to build/convert disc images:
  - `ZipToIso` — presses a folder of files (in a `.zip`) into an ISO9660 + Joliet CD.
  - `IsoReader` — minimal ISO9660 reader for auto-picking programs / extracting CDs.
  - `Fat32Disk` — creates a sparse MBR + FAT32 hard-disk image for the Win98 data drive.

## Project layout

```
app/src/main/java/com/dosboxx/app/
  GameLauncherActivity.java   # the launcher UI + conf generation (the core)
  KeyMapStore.java            # per-game gamepad keymaps + joystick-mode flag (JSON)
  KeyMapEditorActivity.java   # UI to rebind pad buttons per game
  IsoReader.java              # ISO9660 reader (scan / extract)
  ZipToIso.java               # zip -> ISO9660+Joliet CD image builder
  Fat32Disk.java              # FAT32 hard-disk image creator
  DosStatus.java              # JNI bridge for the FPS/status overlay
app/src/main/java/org/libsdl/app/
  SDLActivity.java            # SDL2 activity + on-screen keyboard/overlay, CD picker, exit
  ...                         # stock SDL2 Android glue
app/src/main/jniLibs/         # prebuilt native libs (libmain.so = DOSBox-X core, libSDL2.so, ...)
```

## Building

Requires the Android SDK and JDK 17 (Android Studio's bundled JBR works):

```sh
JAVA_HOME=/path/to/jbr ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`local.properties` (pointing `sdk.dir` at your Android SDK) is created by Android Studio
and is intentionally git-ignored.

## Using it

Put content under the app's external files dir
(`Android/data/com.dosboxx.app/files/`):

- `games/` — one subfolder per DOS game, or a disk image. A subfolder containing an
  OS-sized (`>=256 MB`) `.img` is treated as a bootable Windows guest.
- `cds/` — your CD library (`.iso` / `.cue`+data / `.zip`); these show up in the
  Windows-98 tab's changer and (for DOS discs) as playable entries on the MS-DOS tab.

## Native core

`libmain.so` is **DOSBox-X** compiled for `arm64-v8a` and `x86_64`, checked in under
`app/src/main/jniLibs/` so the app builds without a native toolchain.

Upstream DOSBox-X is tracked as a git submodule in [`native/`](native/), pinned to the
release tag matching the shipped binary (`dosbox-x-v2026.06.02`). Our changes go on top
as patch files in `native/patches/` (currently none), and `native/build-android.sh`
drives the NDK cross-build. See [`native/README.md`](native/README.md) for the
update / patch / rebuild workflow.

```sh
git clone --recurse-submodules <repo>      # or: git submodule update --init
```

## Credits

- [DOSBox-X](https://github.com/joncampbell123/dosbox-x) — the emulator (GPL-2.0).
- [SDL2](https://www.libsdl.org/) — Android application glue.

## License

GPL-2.0, matching DOSBox-X (the bundled native core is GPL-2.0). See `LICENSE`.
