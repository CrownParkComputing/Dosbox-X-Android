# DOSBox-X Android

DOSBox-X Android is a handheld-focused Android launcher for DOSBox-X. It is
built around fast game launching, Windows 98 CD installs, and predictable storage
management on handheld Android devices.

## What It Adds

- A unified games launcher for DOS games, CD games, and Windows 98.
- A first-run setup wizard that makes the user choose or confirm storage.
- A storage manager for archives, extracted CDs, visible images, imports, and
  installed games.
- ZIP/7Z CD source collection with optional kept extracted copies.
- One temporary extracted CD mount at a time for archive-backed launches.
- Windows 98 CD setup with the selected CD mounted as `D:`.
- Per-game CD/rip metadata and remembered CD source selection.
- Gamepad, keyboard overlay, mouse, and trackpad integration.

## Storage Model

The app creates a base folder containing:

```text
games/
cds/
cds/.archives/
cds/.prepared-cds/
cds/.extracted-cds/
import/
```

`cds/.archives/` stores ZIP/7Z source packages. These do not appear as launcher
rows. Use `+ Add CD game` to select them.

`cds/.prepared-cds/` is temporary. The app clears old `run_*` folders before
preparing another archive-backed CD.

`cds/.extracted-cds/` stores kept extracted copies when the user ticks `Keep
extracted copy`.

## Windows 98 CD Installs

When starting a Windows 98 CD game setup, the launcher mounts:

- Win98 hard disk as `C:`
- selected CD-ROM as `D:`

This matches old installers that expect the CD drive to be `D:`.

## Build

```sh
./gradlew -Dorg.gradle.java.home=/opt/android-studio/jbr assembleDebug
```

Install:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Repository

Source: <https://github.com/CrownParkComputing/Dosbox-X-Android>

License: GPL-2.0
