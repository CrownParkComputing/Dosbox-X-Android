# Why Windows 95/98 is not supported

Support for booting a Windows 9x hard-disk image was built, proven to reach
the desktop on a real device, and then removed. This is the record of why, so
nobody rebuilds it expecting a different outcome.

## It worked, and that was the problem

A Windows 98 SE image booted to the desktop on a Retroid Pocket Flip 2
(arm64, Android 13), installed its own PnP drivers, and took mouse input. The
machine was real. What could not be made to work was anything worth running on
it.

## The CPU core

DOSBox-X has two: a recompiler and an interpreter. The recompiler comes in two
flavours, and its own help text for `[cpu] core` says:

> Windows 95 or other preemptive multitasking OSes will not work with the
> dynamic_rec core.

`dynamic_x86` is the flavour that does work with Windows, and it is x86-host
only -- in `src/dosbox.cpp` the `cores[]` list guards it behind
`C_DYNAMIC_X86`, which is off on ARM. There, "dynamic" IS dynamic_rec.

**So on an ARM device no working recompiler exists for a Windows 9x guest.**
That was confirmed empirically before the documentation was found: with
`core=dynamic` the boot died partway and the next attempt came up on "Windows
did not finish loading on the previous attempt", with only Safe mode
surviving. With `core=normal` the same image booted normally every time.

## What the interpreter costs

Windows itself runs. A 3D game of that era does not: it renders through the
software Voodoo rasterizer, driven by an interpreted CPU, which is roughly two
orders of magnitude short of playable.

The symptom is worth recognising, because it looks like a crash and is not:
**a black screen with perfectly healthy audio**. The emulated sound card keeps
producing samples on schedule while a single frame takes minutes. Audio
callbacks show no underruns; the engine process is fine; nothing has failed.

Shipping that would mean an app that appears to support Windows and
disappoints every time it is used for it.

## What was kept

DOS is not a preemptive multitasking OS, so the dynrec caveat does not apply
to it. DOS titles keep `core=dynamic`, including 3D ones.

Several fixes found while chasing Windows were real bugs in the DOS paths and
stayed:

- **`imgmount 2 <img> -t hdd -fs none`** -- the drive is named by BIOS NUMBER.
  `-fs none` attaches a raw BIOS disk and imgmount rejects a drive letter
  outright, so the previous `imgmount c` had never worked for any boot image.
- **`locking disk image mount=false`** -- `fopen_lock()` flocks the image and,
  if the lock fails, closes the file and reports failure. FUSE-backed storage
  (any Android SD card) does not support flock, so a present, readable,
  byte-perfect image reported "Could not open the specified VHD file".
- **`user_cursor_locked`** -- DOSBox-X only accumulates PS/2 mouse movement
  while it believes the mouse is captured, and that flag is set from a real
  SDL mouse-motion event which a headless core never receives. The bridge now
  forces it. Before this, no guest ever saw pointer movement, only buttons.
- **Dynamic VHD sizing** -- an unfilled dynamic VHD is a few hundred bytes on
  disk while describing gigabytes. The virtual size is read from the footer.

## In the app

`WhyNotWindowsScreen` says all of this in the user's terms. A bootable image
that describes 300MB or more is taken to be an installed OS rather than a DOS
boot disk, is labelled "Windows image - not supported" in the library, and
opens that explanation instead of booting. Disk images are never modified.

## If you want Windows

Use a PC emulator rather than a DOS emulator that can host one. 86Box emulates
the hardware itself and is the right tool for a Windows 98 install.
