FreeDOS 1.3 boot floppy (FD13BOOT.img)
======================================

WHAT THIS IS
  An unmodified FreeDOS 1.3 boot floppy image, taken from the official
  Floppy Edition (144m/x86BOOT.img). It is a complete, freely redistributable
  DOS: kernel, COMMAND.COM and the standard utilities.

WHY IT IS HERE
  So the app can boot a real DOS with nothing supplied by the user. This app
  ships no MS-DOS and never will -- MS-DOS is Microsoft's. FreeDOS is the free
  software replacement for it, and shipping it is what lets someone who owns no
  DOS at all still see the emulator run.

  DOSBox-X also provides its own built-in DOS, which is what the app uses by
  default: it is faster to start and needs no boot at all. FreeDOS is the other
  mode, for software that wants a real DOS underneath it.

LICENCE
  FreeDOS is free software. Its kernel is distributed under the GNU General
  Public License v2, and the bundled utilities under their own free licences
  (GPL, BSD and public domain, varying by package). The complete distribution,
  including full source code and per-package licence texts, is at:

      https://www.freedos.org/
      https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.3/

  This image is redistributed unmodified. No part of FreeDOS is authored by
  this project.

PROVENANCE
  Downloaded from the FreeDOS 1.3 official Floppy Edition
  (FD13-FloppyEdition.zip), file 144m/x86BOOT.img.
  1,474,560 bytes -- a standard 1.44MB floppy image, FAT12, label "FD13-BOOT".
