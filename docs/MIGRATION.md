# Migration from Dosbox-X-Android

This project replaces the Java/SDL Android app at
`~/StudioProjects/Dosbox-X-Android` with a Flutter front end targeting Android,
iOS and Linux. It follows the architecture of its sibling, ViceMultiplatform:
a plain-C bridge over the emulator core, `dart:ffi` bindings, and a Flutter UI
that polls a framebuffer.

## The architectural change

The old app let SDL own everything. `SDLActivity` created a `SurfaceView`, SDL2
rendered into it, SDL2 owned audio and input, and the Java layer only generated
a `dosbox-x.conf` and launched an Activity. That works on Android and nowhere
else, which is why it had to change.

The new app inverts it: the core renders into an offscreen buffer that Flutter
draws, and Flutter injects input. This is possible because DOSBox-X already has
an offscreen output backend -- see `docs/NATIVE_BUILD.md`.

What survives unchanged is the launch mechanism: a generated `dosbox-x.conf` is
still the only channel by which a title is launched. That decision was right
and is preserved deliberately.

## Parity checklist

### Done

- [x] C ABI contract (`native/dosbox_core/bridge/dosbox_bridge.h`)
- [x] FFI bindings, core interface, stub core
- [x] Config generation, ported with every compatibility workaround intact
      (`lib/services/dos_conf_builder.dart`) -- see below
- [x] Library scanning: folder games, disc images, boot images, archives
- [x] Per-title settings (CPU preset, Voodoo, joystick) replacing `GameMeta`
- [x] Library grid with search and format filter
- [x] Emulator screen: framebuffer, on-screen stick, action buttons, key strip,
      trackpad mouse, physical keyboard passthrough
- [x] Generated engine settings screen, replacing `DosConfigActivity`
- [x] Video, input and paths settings; setup wizard; about
- [x] Gamepad support, storage permissions, Android host activity
- [x] 28 tests covering config generation, the stub core and the library grid

### Not done

- [ ] **The native bridge itself.** The app runs on `StubDosboxCore`.
- [ ] **Audio.** See `docs/NATIVE_BUILD.md`.
- [ ] **Save states.** The C API is designed (`dosbox_core_save_state`, slot
      based) but there is no Dart `SaveStateService` and no thumbnails yet.
- [ ] **Media import.** The Java `ArchiveExtractor`, `IsoReader`, `ZipToIso`,
      `Fat32Disk` and `Fat32Reader` -- roughly 3000 lines of ISO9660 and FAT32
      binary parsing -- are being ported to Dart and are not started. Until
      then archives are listed but cannot be imported, and the Windows 9x
      features below depend on them.
- [ ] **Windows 9x support.** Boot images are launchable, but the games-disk
      (FAT32 `D:`) workflow, installing Windows games from CD, copying games
      off `D:`, and the graceful-shutdown key injection are all absent.
- [ ] **CD changer UI.** Multi-disc swap sets are mounted correctly by the conf
      builder, but there is no in-session disc-swap control.
- [ ] **Win98 image download.** Deliberately dropped rather than deferred; it
      is a licensing question, not an engineering one.
- [ ] **`.bin` cue-sheet generation.** `_discMountLines` routes raw tracks
      correctly but the `.cue` the Java app generated on the fly is not written
      yet, so a bare `.bin` will not mount.
- [ ] **iOS.** The Dart layer is platform-clean and `flutter build ios` should
      work, but there is no native core, so nothing runs.

## Compatibility knowledge preserved from the Java app

These are the non-obvious constants in `dos_conf_builder.dart`. Every one came
from a real title failing. They have tests, and they should not be "tidied"
without a specific game to test against.

| Behaviour | Reason |
| --- | --- |
| `memsize=32`, never 64+ | DOS/4GW 1.97 fails with "Unable to find <game>.exe in ''" at 64MB+. IndyCar Racing 2. |
| Mount the *parent* for folders matching `indy` | IndyCar asks DOS/4GW for its own path; from the C: root it gets an empty string and dies. |
| `sbtype=sbpro2`, not `sb16` | sbpro2's 8-bit DMA plays digital effects reliably; sb16's 16-bit DMA often goes silent. |
| Setup programs get `cycles=fixed 20000` | They probe hardware with delay loops and misbehave at `max`. |
| Screamer's setup gets `fixed 12000` + `vesa_nolfb` | Crashes at `max`; misdetects under `svga_s3`. |
| Screamer proper gets `fixed 150000` | Needed for sane game speed. |
| 3dfx executables get `fixed 100000` and a 2048-byte audio block | The software rasterizer needs headroom, and triangle-heavy frames underrun a small audio buffer. |
| `core=normal` for the 80s preset | The dynamic core recompiles blocks, which self-modifying old software defeats. |
| Prefer `.bat` over `.exe` | Shipped batch files set up the environment (sound variables, CD paths) the bare executable assumes. |
| Paths always quoted | Android paths contain spaces as a matter of course. |

## Deliberate divergences from the Java app

- **`render.aspect=false`, with aspect applied in Flutter.** The old app forced
  this too, but because the Android GPU path did the scaling. Here the reason is
  different: `FramebufferView` applies the ratio the core reports per video
  mode. DOS modes are frequently non-square-pixel (320x200 is 4:3) and
  frequently not (320x240 is square), so a hardcoded 4:3 -- which the VICE app
  can safely use -- would stretch half the library.
- **The emulated joystick defaults to off.** Most DOS games are keyboard-only
  and a few misbehave when they detect an idle joystick. The old app always
  exposed it.
- **Scancodes, not characters, throughout.** DOS reads the keyboard at the
  scancode level, and physical-key passthrough means positional WASD works on a
  non-QWERTY host layout.
- **No `:emu` process.** Not a choice -- Flutter is single-process. It is why
  the shutdown limitation is now user-visible instead of hidden.
