# Retro-Dosbox — SDL3 + ImGui rewrite plan

Replace the Flutter front end with a native SDL3 + Dear ImGui application, in the
shape retro-x86 uses, targeting **Android and iOS only**.

> Decisions taken 2026-09-01:
> - **Core stays DOSBox-X.** It is the only fork with first-class Win3.x/Win9x
>   support, and the existing bridge, patches and audio backends are a large,
>   working investment. DOSBox Staging has migrated to SDL3 but puts Win9x
>   explicitly out of scope; DOSBox Pure is a libretro core with a UI philosophy
>   that fights an ImGui menu.
> - **Scope is DOS + Windows 3.x.** Win9x guest support stays disabled behind the
>   existing "Windows image – not supported" gate (`docs/WINDOWS_9X.md`).
> - **Linux is not a shipped target**, but remains the development and test host.
>   Every gate below runs there first; the device is for confirmation only.

## 1. Why this is a front-end replacement, not a rewrite

`native/dosbox_core/bridge/dosbox_bridge.h` is already a complete, plain-C,
**UI-agnostic** ABI — lifecycle, framebuffer (+ cross-process shared frames),
keyboard/mouse/joystick, save states, live config *reflection*, mid-session CD
swap, status. Nothing in it is Flutter-specific.

So the core, the bridge, the patches and the audio backends all survive. What is
replaced is `flutter_app/` — 57 Dart files, ~14.7k lines — by a C++ SDL3 + ImGui
app consuming the same ABI.

The Dart in `lib/services/` is *logic*, not UI: conf generation, 8.3 sanitising,
library scanning, VHD sniffing, save-state indexing. It gets **ported**, not
redesigned. Its 10 test files (1449 lines) define the behaviour to preserve.

## 2. The template, and where it stops

retro-x86 is a **fork of 86Box** with three grafts: an in-tree ImGui OSD
(`src/osd/`), a `*_CORE_LIBRARY` CMake branch exposing one plain-C header, and
clients above it. The reusable pattern is the seam:

- `src/osd/osd_core.{cpp,hpp}` — **backend-neutral** ImGui UI. Knows nothing
  about the frontend; talks to it through a two-callback `osd_host_t` vtable.
- `src/osd/osd_explorer.{cpp,hpp}` — a reusable file browser (814 lines) with an
  `Open(config)` / `Draw() -> {None|Accepted|Cancelled, path}` contract.
- `src/unix/sdl_osd.cpp` — the thin SDL3 host: `ImGui_ImplSDL3_InitForSDLRenderer`
  + `ImGui_ImplSDLRenderer3_Init`, `osd_open/close/handle/present`.

**Where the template stops:** retro-x86's SDL3+ImGui path is **Linux-only**.
`app/android/` is a stock Flutter template with no `externalNativeBuild`; there
is no SDL3 Android activity and no iOS native target. Its OSD also has **no
settings screen** and **no touch controls** — both of which we need. So we copy
the *structure*, and write the mobile shells and the touch layer ourselves.

## 3. Architecture

```
app/                              NEW — replaces flutter_app/
  CMakeLists.txt                  one build, three platforms (android/ios/linux-dev)
  src/
    main.cpp                      SDL3 entry; SDL_AppInit/Iterate/Event/Quit
    host/
      host_sdl3.{h,cpp}           window, renderer, emulator texture, present
      host_input.{h,cpp}          keyboard/mouse/gamepad -> bridge
      host_paths.{h,cpp}          per-platform dirs (support/captures/conf)
    core/
      core_client.{h,cpp}         dlopen + dlsym of libdosboxcore, typed via the header
    ui/
      ui_core.{h,cpp}             backend-neutral RMU root; view stack; ui_host_t vtable
      ui_library.cpp              game grid, import, per-title settings
      ui_explorer.cpp             file browser (ported from osd_explorer.cpp)
      ui_settings.cpp             GENERATED from config reflection JSON
      ui_savestates.cpp           10 slots, thumbnails, naming
      ui_pause.cpp                pause menu, disc swap, quit
      ui_touch.cpp                on-screen keyboard, trackpad, virtual pad
      ui_wizard.cpp               setup wizard + store-compliance gate
    services/                     ports of lib/services/*.dart
      conf_builder.{h,cpp}        <- retrodosbox_conf_builder.dart (593 lines)
      library_scanner.{h,cpp}     <- library_scanner.dart (437)
      dos_name.{h,cpp}            <- 8.3 sanitiser
      disk_image.{h,cpp}          <- VHD footer parse (drives the Win9x gate)
      prefs.{h,cpp}               <- shared_preferences -> JSON file
      zip_import.{h,cpp}          <- zip_runner/zip_importer
      save_state_service.{h,cpp}
    platform/
      android_storage.cpp + JNI   SAF / all-files access, gamepad
      ios_storage.mm              UIDocumentPicker, Files integration
  imgui/                          vendored ImGui + impl_sdl3 + impl_sdlrenderer3
  android/                        Gradle + SDLActivity shell
  ios/                            Xcode project / CMake iOS toolchain
```

Three rules carried from the template:

1. **`ui_core` never calls SDL or the platform directly.** It gets a `ui_host_t`
   vtable (toggle fullscreen, quit, pick folder, show keyboard, …). This is what
   makes the same UI compile for Android, iOS and the Linux dev host.
2. **New capability = new export on `dosbox_bridge.h`**, never a platform side
   channel. (retro86_host.h states this rule; it is the right one.)
3. **ImGui layout is not persisted** (`io.IniFilename = nullptr`). All durable
   state goes through our own prefs/conf files.

### Rendering

Bridge publishes `0xAARRGGBB` little-endian = `SDL_PIXELFORMAT_ARGB8888`, so the
emulator frame uploads with no conversion. Poll `dosbox_core_get_frame_counter()`
and skip the upload entirely when unchanged — DOS text mode sits on an identical
frame for seconds. Honour `out_pitch_bytes` (render pitch is not always `w*4`)
and aspect-correct with `dosbox_core_get_pixel_aspect_x1000()` (320x200 is 4:3,
not 16:10). ImGui draws on top via `SDL_Renderer3`, which gives us GLES on both
platforms without a bespoke GL path.

### Settings, for free

`dosbox_core_config_section_properties()` returns JSON per section with
`name/type/value/default/help/values[]`. The settings screen is **generated** from
that — widget chosen by `type`, combo populated from `values[]`. No hand-maintained
duplicate of DOSBox-X's property list. Needs a small JSON reader (nlohmann/json,
MIT, GPLv2-compatible).

## 4. The two risks that must be settled before any UI is written

### 4.1 SDL2/SDL3 symbol collision — **superseded: the core is being ported to SDL3**

> **Update 2026-09-01:** the decision is to port DOSBox-X itself to SDL3 on our own
> branch — see `SDL3_CORE_PORT.md`. With one SDL version in the process this
> collision cannot occur, and the sealing work below is unnecessary. The section
> is kept because it documents *why* the core's symbol surface matters, and the
> version-script hygiene is still worth having.



The core dynamically links SDL2 (`libSDL2.so` in `NEEDED`), needs **126 SDL2
symbols** including patched ones (`SDL_DBX_SetContentSize`,
`SDL_DBX_InvalidateWindowSurface`), and **exports 2133 symbols** globally —
including `SDL_main` and `SDL_CDResume`.

An SDL3 frontend puts libSDL2 and libSDL3 in one process, and both use `SDL_*`
names. **iOS is safe** (Mach-O two-level namespace records the defining dylib).
**Android is not** — the ELF linker binds by name, so the core's `SDL_Init` may
bind into libSDL3. Silent and catastrophic.

**Fix:** link SDL2 statically into `libdosboxcore.so`, build with
`-fvisibility=hidden`, and add a version script exporting only `dosbox_core_*`
and `dosbox_shared_frame_*`. The core is headless (gamelink output,
`SDL_VIDEODRIVER=dummy`, audio via our own AAudio/CoreAudio backends), so nothing
outside needs its SDL. Gate: `nm -D --defined-only` lists only the bridge ABI.

### 4.2 Does `dosbox_core_stop()` really return cleanly? — **decides the process model**

DOSBox-X is documented as one-shot ("ending a session has to mean ending a
process"), which is why Android runs the engine in a `:dosbox` service. But
`dosbox_core_stop()` claims a bounded clean teardown, and the `GFX_Events()` pump
fix was recorded as making it reliable.

This matters because **iOS cannot spawn processes.** If stop() is not reliable:

- Android can keep the separate-process model (the shared-frame mmap API already
  exists), but
- iOS would have to *exit the app* to leave a game — an App Store rejection risk
  and a bad experience.

So stop() reliability is on the critical path for iOS specifically. Gate: extend
`check-core.sh` to run start/stop **20 consecutive times in one process**,
checking the return value each time (it previously printed "clean"
unconditionally, which hid exactly this bug).

## 5. Core build pipeline — three things to fix

1. **The source tree is missing.** `~/dosbox-x-src` is gone; only `~/dosbox-x-pic`
   remains. Re-clone upstream fresh (tree in repo is `2026.08.02`; take current
   master, per "latest DOSBox-X core").
2. **The Android build depends on a retired app.** `android/build.sh` symlinks
   prebuilt SDL2/libpng out of `~/AndroidStudioProjects/DosBoxX/...` and fakes an
   `sdl2-config` shim. That is unreproducible on any other machine and blocks CI.
   Build SDL2 + libpng from source, pinned by tag, as the iOS Dockerfile already
   does.
3. **The shared `~/dosbox-x-pic` tree is single-config** — Android reconfigures it
   in place, so host and Android builds clobber each other. Give each target its
   own build tree.

### Patch series shrinks

Headless gamelink means the frontend owns the window, so the SDL2 window-scaling
patches lose their reason to exist:

| Patch | Fate |
|---|---|
| 0001 android configure target | keep |
| 0002 SDL1 CD-ROM include | keep |
| 0003 sdlmain (suppress tinyfd/x11) | keep, extend to force `DOSBOXMENU_NULL` |
| 0004 render aspect | **drop** — frontend aspect-corrects |
| 0005 output surface GPU scale | **drop** — no on-screen SDL window |
| 0006 SDL2 GPU content scale | **drop** — removes the `SDL_DBX_*` SDL2 fork dependency |
| 0007 native config GUI | **drop** — superseded by the bridge's config reflection |
| 0008 gamelink `shm_open` bionic-safe | keep |
| 0009 synthetic joystick at init | keep |

Dropping 0004–0006 is what lets us use **stock SDL2**, which is what makes the
static-link seal in §4.1 straightforward. This is also the user's "strip the
DOSBox-X menu and rebuild what's needed in our RMU."

## 6. Work phases

Each phase ends at a gate that runs **on the Linux host**. Device runs are
confirmation, not discovery.

**Phase 0 — spikes (no UI).**
- Fresh upstream clone builds; reduced patch series applies.
- Sealed `.so`: `nm -D` shows only the bridge ABI.
- 20x start/stop clean in one process → picks the process model.

**Phase 1 — core build pipeline.** Android (arm64 + x86_64) and iOS built with no
legacy host dependencies, SDL2/libpng from source. Strip the 91 MB arm64 `.so`
(x86_64 is 17 MB — the two ABIs are currently out of step).

**Phase 2 — app skeleton.** SDL3 window + ImGui + framebuffer texture + hardware
keyboard, running a DOS game on the Linux dev host. Proves the render/input path
before any menu work.

**Phase 3 — the RMU.** View stack, library, explorer, generated settings, save
states, pause menu, disc swap.

**Phase 4 — touch layer.** On-screen keyboard, trackpad-mouse grammar, virtual
pad, movable/custom buttons — ported from `lib/widgets/` and
`touch_pointer_gestures.dart`. This is the biggest piece with **no template**;
retro-x86's OSD has nothing equivalent.

**Phase 5 — Android shell.** SDLActivity, storage/SAF, gamepad, AAudio, Gradle,
signing. Keep `applicationId com.dosboxx.app` (in-place upgrade of the retired
Java app — the user's game library depends on it).

**Phase 6 — iOS shell.** SceneDelegate, document picker, CoreAudio, packaging.
Carry the five iosbox-vs-Xcode gaps already documented (native assets as a real
`.framework`, literal `Runner.SceneDelegate`, no storyboard, explicit
`UIDeviceFamily`, SceneDelegate window reset).

**Phase 7 — parity + release.** Port the 10 Dart test files to C++ host tests
(conf golden files, 8.3 sanitiser, VHD sniffing). Restore the store-compliance
mode (FreeDOS demo, App Review 4.7 — the index is required in Review Notes every
submission). Fix the stale `native-core.yml` CI, which still references paths
that no longer exist.

## 7. Things to carry across, easy to lose

- **`memsize=32`** (DOS/4GW 1.97 bug), `sbtype=sbpro2`, per-title cycles
  (Screamer `fixed 12000`/`150000`, setup `fixed 20000`), `.bat` preferred over
  `.exe`, everything quoted.
- **`locking disk image mount=false`** — `flock()` fails on FUSE-backed SD cards,
  and the symptom is indistinguishable from a missing/corrupt image.
- **`imgmount 2 <img> -t hdd -fs none` then `boot -l c`** — a BIOS drive *number*,
  not a letter. The old `imgmount c ... -fs none` form never worked.
- **8.3 sanitising at import** — DOS 5 has no LFN, so `boulder dash.exe` is
  unreachable.
- **minSdk 28** — bionic gained `iconv_open` there.
- **`abiFilters` must be re-set** in `buildTypes.configureEach`; the Flutter
  Gradle plugin re-adds armeabi-v7a. (Re-check what the non-Flutter Gradle build
  needs here.)

## 8. Cleanup this enables

- `DosboxEmulatorActivity.kt` — extends `SDLActivity`, declared in the manifest,
  **never started from anywhere**. Two competing architectures are in the tree;
  only the shared-framebuffer one runs. Delete.
- The `org/libsdl/app/*.java` stubs and hand-rolled `SDL.setupJNI()` exist only
  because SDL2's Android backend assumed its host was `SDLActivity` while ours was
  a `FlutterActivity`. With a real SDL3 app this whole class of hack disappears.
- Asset path mismatch: `RetroDosboxNativePaths` extracts `assets/dosbox/` while
  `pubspec.yaml` ships `assets/retrodosbox/` — the DOSBox-X resource tree is not
  actually bundled today, only a placeholder README.
- `README.md` and `docs/PLATFORM_STATUS.md` still claim the app runs on
  `StubDosboxCore` with no core-backed build; both are months stale.
