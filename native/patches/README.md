# Patches

Our changes to upstream DOSBox-X, layered on top of the pinned `native/dosbox-x`
submodule. Each file is a `git diff` / `git format-patch` output applied in filename
order (`0001-*.patch`, `0002-*.patch`, …) by `../build-android.sh` before building.

Empty for now — the shipped `libmain.so` is stock upstream `dosbox-x-v2026.06.02`.

See `../README.md` for how to create and apply patches.
