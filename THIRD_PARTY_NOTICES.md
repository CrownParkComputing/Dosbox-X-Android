# Third-Party Notices

DOSBox-X Android is distributed under the GNU General Public License version 2.
See [LICENSE](LICENSE).

## DOSBox-X

This app includes a modified Android build of DOSBox-X.

- Project: https://dosbox-x.com/
- Source: https://github.com/joncampbell123/dosbox-x
- Upstream source snapshot: [native/dosbox-x](native/dosbox-x)
- License: GNU General Public License version 2, see
  [native/dosbox-x/COPYING](native/dosbox-x/COPYING)

DOSBox-X itself is based on DOSBox and contains additional third-party
components and credits. See [native/dosbox-x/CREDITS.md](native/dosbox-x/CREDITS.md)
and license files under [native/dosbox-x](native/dosbox-x).

## Bundled Native Libraries

The Android package includes native shared libraries built from or used by the
DOSBox-X Android port:

- `libmain.so`: DOSBox-X Android native code, GPLv2 as part of this project
- `libSDL2.so`: SDL 2.0, zlib license
- `libpng16.so`: libpng license
- `libc++_shared.so`: Android NDK C++ runtime

## Source Availability

The complete corresponding source for this app, including the Android launcher,
native integration, build scripts, and DOSBox-X submodule, is published at:

https://github.com/CrownParkComputing/Dosbox-X-Android

If you receive a binary copy of this app, you may copy, modify, and redistribute
it under the GPLv2. The GPL permits charging for copies, but recipients keep the
GPL rights to source code and redistribution.

## External Content

This repository and app do not include Microsoft Windows disk images, game ROMs,
game ISOs, game files, BIOS files, or other third-party copyrighted content.
Users are responsible for supplying only content they have the right to use.
