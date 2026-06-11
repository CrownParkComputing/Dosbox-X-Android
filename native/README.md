# Native core (DOSBox-X) — upstream + patches

The Android app loads a native shared library, `libmain.so`, which is **DOSBox-X**
compiled for Android. This directory tracks that core as an upstream dependency so it
can be kept current and rebuilt, with our changes layered on top as patches.

## Layout

```
native/
  dosbox-x/        git submodule → joncampbell123/dosbox-x, pinned to a release tag
  patches/         our changes on top of upstream, as *.patch files (git format-patch)
  build-android.sh build script: checkout submodule → apply patches → NDK build → jniLibs
```

The prebuilt libs currently shipped in `app/src/main/jniLibs/<abi>/` were built from
the pinned tag (see below) with **no** source patches yet — `patches/` is empty.

## Upstream pin

The submodule is pinned to the tag that matches the shipped binary:

```
dosbox-x-v2026.06.02
```

To move to a newer upstream:

```sh
git -C native/dosbox-x fetch --tags
git -C native/dosbox-x checkout dosbox-x-vYYYY.MM.DD   # the new release tag
git add native/dosbox-x && git commit -m "Bump DOSBox-X to YYYY.MM.DD"
# then rebuild (below) and commit the refreshed jniLibs
```

## Our patches

Keep every change to the DOSBox-X C/C++ source as a patch file in `patches/`, applied
in filename order on top of the pinned submodule — never commit edits inside
`native/dosbox-x` itself. To create one after editing the submodule working tree:

```sh
git -C native/dosbox-x diff > native/patches/0001-description.patch
git -C native/dosbox-x checkout .        # discard the working-tree edit
```

Candidate patches (the reasons we'd build our own core rather than ship upstream's):

- **CD-ROM in a booted Win9x guest** — IDE ATAPI isn't seen by Windows 98
  (dosbox-x #3418); fixing it removes the real-mode-CD / slow-disk trade-off.
- **3dfx Voodoo via GLES** — only the software rasterizer works on Android today;
  a GLES backend for `voodoo_opengl` would accelerate Glide games.

## Building (NDK)

`build-android.sh` documents and drives the cross-build for `arm64-v8a` and `x86_64`.
**Status:** the toolchain/configure steps are scripted, but upstream DOSBox-X has no
Android target of its own (its `configure.ac` has zero Android references), so the
final step — linking the DOSBox-X `main()` as an SDL2 `libmain.so` instead of an
executable — is the custom part that still needs finishing. See the script's comments.

```sh
export ANDROID_NDK=$HOME/Android/Sdk/ndk/<version>
./native/build-android.sh            # → app/src/main/jniLibs/<abi>/libmain.so
```

## Licensing

DOSBox-X is GPL-2.0; the submodule and any patches inherit that. See the repo `LICENSE`.
