# Third-Party Notices

DOSBox-X Multiplatform is distributed under the GNU General Public License version 2.
See [LICENSE](LICENSE).

## DOSBox-X

This app includes a build of DOSBox-X, linked through the plain-C bridge in
`native/dosbox_core/`.

- Project: https://dosbox-x.com/
- Source: https://github.com/joncampbell123/dosbox-x
- License: GNU General Public License version 2

DOSBox-X itself is based on DOSBox and contains additional third-party
components and credits.

## Bundled Native Libraries

The platform packages include native shared libraries built from the DOSBox-X
core via the `native/dosbox_core/` bridge:

- `libdosboxcore.so`: the bridge plus the DOSBox-X core, GPLv2 as part of this project
- `libSDL2.so`: SDL 2.0, zlib license
- `libpng16.so`: libpng license

## FreeDOS Review Environment

The app includes a minimal bootable image derived from the official FreeDOS
1.4 Floppy Edition. It contains the FreeDOS kernel (GNU GPL v2 or later), the
FreeCOM command shell (GNU GPL v2), startup files written for this app, and the
original homebrew demo described below. The official archive hash, component
list, corresponding-source links and reproducible image recipe are in
`flutter_app/assets/demo/FREEDOS.txt` and `tools/build-freedos-demo.sh`.

- FreeDOS kernel source: https://github.com/FDOS/kernel
- FreeCOM source: https://github.com/FDOS/freecom
- License: GNU General Public License version 2; see [LICENSE](LICENSE)

## Retro-DosBox Homebrew Demo

`RETRODEM.COM` is an original 16-bit DOS program created for this app so the
emulator can be reviewed without third-party content. Its complete assembly
source ships beside it in `flutter_app/assets/demo/retro_demo.S`.

- Copyright: 2026 Crown Park Computing
- License: MIT; see `flutter_app/assets/demo/LICENSE.txt`

## Source Availability

The complete corresponding source for this app, including the Flutter front
end, the native bridge, and the build scripts, is published at:

https://github.com/CrownParkComputing/DosboxMultiplatform

If you receive a binary copy of this app, you may copy, modify, and redistribute
it under the GPLv2. The GPL permits charging for copies, but recipients keep the
GPL rights to source code and redistribution.

## External Content

Other than the documented open-source FreeDOS review image and original demo,
this repository and app do not include Microsoft DOS or Windows disk images,
game ROMs, game ISOs, commercial game files, BIOS dumps, activation keys, or
other third-party copyrighted content. Users are responsible for supplying only
content they have the right to use.
