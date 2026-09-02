# Retro-DOS

A DOS games launcher and emulator for handhelds, built on **DOSBox-X** with an
**SDL3 + Dear ImGui** frontend.

This replaces the earlier Flutter application entirely. The Flutter build put a
UI toolkit between the player and a 320x200 picture that has to arrive sixty
times a second, and kept the emulator behind a plugin boundary that made the
things a launcher actually needs — mounting a game, remapping a key while it
runs, reading a frame — awkward or impossible. The frontend is now native and
in the same process as the core.

## Layout

    core/       DOSBox-X, ported to SDL3   (submodule: CrownParkComputing/dosbox-x-sdl3)
    frontend/   the launcher: library, settings, on-screen controls, RetroMedia
    android/    the Android application and its build script
    demo/       bundled content, and the source that generates it

The core is a **submodule rather than a copy**. It is a fork of DOSBox-X with
upstream still attached, which is what keeps its changes mergeable; vendoring
the tree into this repository would end that and duplicate several gigabytes of
sources for nothing.

## Building

    git clone --recurse-submodules https://github.com/CrownParkComputing/Retro-Dosbox.git
    cd Retro-Dosbox/android
    ./build-core.sh          # cross-compiles the core and the frontend
    gradle assembleDebug

`build-core.sh` builds SDL3 and DOSBox-X for the target ABI, compiles the
frontend, links `libretrodos.so`, and installs the result into
`app/src/main/jniLibs` — the directory Gradle actually packages. That last step
is not a convenience: without it Gradle reports BUILD SUCCESSFUL while shipping
the previous library.

If the submodule has not been initialised the script stops and says so, rather
than failing later inside the compiler.

## How a game is run

Each game is a directory, mounted as `C:`. Where a game ships its own
`dosbox.conf` — the collections in this format all do — its `[autoexec]` and
sound settings are used verbatim, because the game states how it starts far
better than we can infer it: Descent's folder alone holds `ASKECHO.COM`,
`JCHOICE.EXE`, `network.bat` and `run.bat`, and only one of those starts the
game. Failing that, a runnable is chosen from the directory, preferring
`run`/`start` over installers and setup programs.

## Controls

A physical gamepad is used when one is connected and on-screen controls appear
when none is. Both feed the same button state, so nothing downstream knows
which was used. What each button *sends* is a per-game setting, because DOS
never agreed on a control scheme — Keen jumps on Ctrl and pogos on Alt, Descent
wants the arrows and six degrees of freedom. Presets are provided and the
mapping can be changed from the in-game menu, while the game is on screen.

## RetroMedia

Signing in to `media.crownparkcomputing.com` fetches box art. Administrators
can also download games. Downloads are gated on the platform as well as the
account: an App Store build does not offer them at all.

## Licensing

DOSBox-X is GPL; see `core/COPYING`. The bundled FreeDOS image and the
demonstration program have their own terms, recorded in `demo/NOTICE.md`.
