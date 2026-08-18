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

## Source Availability

The complete corresponding source for this app, including the Flutter front
end, the native bridge, and the build scripts, is published at:

https://github.com/CrownParkComputing/DosboxMultiplatform

If you receive a binary copy of this app, you may copy, modify, and redistribute
it under the GPLv2. The GPL permits charging for copies, but recipients keep the
GPL rights to source code and redistribution.

## External Content

This repository and app do not include Microsoft Windows disk images, game ROMs,
game ISOs, game files, BIOS files, or other third-party copyrighted content.
Users are responsible for supplying only content they have the right to use.
