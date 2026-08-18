# Our patches on top of upstream DOSBox-X

Every change we make to the DOSBox-X C/C++ source lives here as a `*.patch` file,
applied in filename order on top of the pre-built `~/dosbox-x-pic` tree by
`../build.sh`. We never edit the DOSBox-X tree directly — it stays a clean,
re-producible checkout so it can be refreshed freely.

## Current patches

| File | What it does | Why Android needs it |
|------|--------------|----------------------|
| `0001-android-configure-target.patch` | Adds an `*-*-android*` case to `configure.ac` (defines `LINUX`+`ANDROID`, but no `-lrt`, no parallel-port pass-through). | The `aarch64-linux-android` triple otherwise hits the `*-*-linux*` case, which links `-lrt`; bionic has no `librt`. |
| `0002-android-sdl1-cdrom-include.patch` | SDL1 CD-ROM backend includes `<linux/cdrom.h>` on Android. | Include was gated on SDL's `__LINUX__` (unset on Android), so the ioctl code compiled without its header. Dead code on Android (CD = image mounts) but must compile. |
| `0003-android-sdlmain.patch` | (a) Force `opt_promptfolder=0` (no tinyfd folder dialog → no startup hang). (b) Don't force `SDL_VIDEODRIVER=x11` on Android (let SDL pick `android`). | Without (a)/(b) the app hangs/crashes at startup. |
| `0004-android-render-aspect.patch` | Force `render.aspect = ASPECT_FALSE` on Android. | The GPU does aspect-fit scaling; never run the CPU post-render scaler. |
| `0005-android-output-surface-gpu-scale.patch` | `OUTPUT_SURFACE_SetSize` Android branch: render DOS+menu into a content-sized surface and invalidate after mode set. | Makes the small DOS framebuffer fill the display (GPU-scaled). |
| `0006-android-sdl2-gpu-content-scale.patch` | Vendored SDL2 GPU content-scale (`SDL_DBX_*`). | Implements the GPU scaling 0005 drives. Kept for SDL2 reproducibility; the shipped `libSDL2.so` already contains it. |
| `0007-android-native-config-gui.patch` | `configure.ac`/build wiring for the native config reflection — the direct ancestor of `dosbox_core_config_*` in the bridge. | The Flutter settings screen drives the core's config through the bridge instead of the Java JNI reflection. |
| `0008-android-gamelink-shm-open.patch` | Replaces Game Link's `shm_open`/mmap with the in-process buffer path. | bionic has no `shm_open`; the bridge hands out its own framebuffer instead of shared memory. |
| `0009-android-enable-synthetic-joystick-at-init.patch` | Expose the synthetic joystick before DOS startup. | DOS programs probe the joystick at boot; exposing it late means they never see it. |

> **Feature flags (not patches)** live in `build.sh` and never need refreshing:
> `--disable-opengl --disable-alsa-midi --disable-sdlnet --disable-libslirp
> --disable-libfluidsynth --disable-x11`.

## SDL2 / libpng note

`build.sh` links `libdosboxcore.so` against the **prebuilt** `libSDL2.so` and
`libpng16.so` (originally taken from the legacy app's `jniLibs`). Patch 0006 is
**not compiled by the libdosboxcore build**; it is kept here so the vendored
SDL2 stays reproducible. If you ever rebuild `libSDL2.so` from `vs/sdl2`, apply
0006 first, then drop the result into `jniLibs/`.

## Creating / refreshing a patch

Edit files under `~/dosbox-x-pic/` (a git checkout), then capture per concern
with `git diff` into a new numbered `*.patch` file here. There is no helper
script — the ordering in the filename is what `apply-android-source.py` honours.
