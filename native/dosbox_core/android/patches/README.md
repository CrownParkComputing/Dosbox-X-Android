# Our patches on top of upstream DOSBox-X

Every change we make to the DOSBox-X C/C++ source lives here as a `*.patch` file,
applied in filename order on top of the pinned upstream tag by
`../build-android.sh`. We never commit edits inside `native/dosbox-x` itself — the
submodule always stays at clean upstream so it can be bumped freely.

## Current patches

| File | What it does | Why Android needs it |
|------|--------------|----------------------|
| `0001-android-configure-target.patch` | Adds an `*-*-android*` case to `configure.ac` (defines `LINUX`+`ANDROID`, but no `-lrt`, no parallel-port pass-through). | The `aarch64-linux-android` triple otherwise hits the `*-*-linux*` case, which links `-lrt`; bionic has no `librt`. |
| `0002-android-sdl1-cdrom-include.patch` | SDL1 CD-ROM backend includes `<linux/cdrom.h>` on Android. | Include was gated on SDL's `__LINUX__` (unset on Android), so the ioctl code compiled without its header. Dead code on Android (CD = image mounts) but must compile. |
| `0003-android-sdlmain.patch` | (a) Force `opt_promptfolder=0` (no tinyfd folder dialog → no startup hang). (b) Don't force `SDL_VIDEODRIVER=x11` on Android (let SDL pick `android`). (c) `GFX_SetSDLWindowMode`: keep the window at full display size. (d) `GFX_SetTitle` caches the status line to `android_status_line` + the `DosStatus.getStatusLine` JNI getter for the FPS overlay. | Without (a)/(b) the app hangs/crashes at startup; (c) is half of fullscreen scaling; (d) feeds the Java FPS overlay (a native method — must exist or it throws `UnsatisfiedLinkError`). |
| `0004-android-render-aspect.patch` | Force `render.aspect = ASPECT_FALSE` on Android. | The GPU does aspect-fit scaling; never run the CPU post-render scaler. |
| `0005-android-output-surface-gpu-scale.patch` | `OUTPUT_SURFACE_SetSize` Android branch: render DOS+menu into a content-sized surface via `SDL_DBX_SetContentSize`, set the DOS clip below the menu bar, and `SDL_DBX_InvalidateWindowSurface` after the mode set. | Other half of fullscreen scaling: makes the small DOS framebuffer fill the display (GPU-scaled) instead of sitting tiny in a corner. |
| `0006-android-sdl2-gpu-content-scale.patch` | **Vendored SDL2** (`vs/sdl2/src/video/SDL_video.c`): exported `SDL_DBX_SetContentSize`/`SDL_DBX_InvalidateWindowSurface`, a content-sized window texture, and a GPU aspect-fit `RenderCopy` to the real render output each present. | Implements the GPU scaling that 0005 drives. **See the SDL2 note below.** |

> **Feature flags (not patches)** live in `build-android.sh` and never need
> refreshing: `--disable-gamelink` (uses `shm_open`, absent on bionic),
> `--disable-opengl --disable-alsa-midi --disable-sdlnet --disable-libslirp
> --disable-libfluidsynth --disable-x11`.

## SDL2 note (patch 0006)

`build-android.sh` links `libmain.so` against the **prebuilt** `libSDL2.so` in
`app/src/main/jniLibs/`, which already contains the `SDL_DBX_*` GPU-scaling code —
so patch 0006 is **not compiled by the libmain build**; it's kept here so the
vendored SDL2 stays reproducible. If you ever rebuild `libSDL2.so` from
`vs/sdl2`, apply 0006 first (build SDL2 via its CMake + the NDK toolchain, with
`-Wl,--allow-multiple-definition`), then drop the result into `jniLibs/`.

## Creating / refreshing a patch

Edit files under `native/dosbox-x/`, then capture per concern:

```sh
./native/regen-patch.sh 0007 short-description    # -> patches/0007-short-description.patch
```

When an upstream bump makes a patch stop applying, the build halts with the exact
fix command (`git apply --3way …` then re-`regen-patch.sh`).
