#!/usr/bin/env python3
"""Teach DOSBox-X's configure.ac to tell iOS apart from macOS.

Both report `*-*-darwin*`, and configure.ac says so itself:

    dnl We have a problem here: both Mac OS X and Darwin report
    dnl the same signature ... For now I am lazy and do not add
    dnl proper detection code.

So an iOS cross build takes the macOS branch and picks up Carbon, AppKit,
ApplicationServices and IOKit -- none of which exist on iOS. Every link probe
configure runs then fails, which surfaces as nonsense like "Can't find libpng"
even when libpng is sitting right there in the prefix.

The host triple cannot carry the distinction (config.sub does not accept an
`ios` OS), so the discriminator is the -target flag already in CFLAGS, which is
what actually decides what is being built.

MACOSX stays defined: the source uses it for Darwin-common things (endianness,
paths, dyld) that are equally true on iOS. Only the framework list changes.
Idempotent; the anchor is the framework line itself.
"""
import os
import sys

TREE = sys.argv[1] if len(sys.argv) > 1 else "."
path = os.path.join(TREE, "configure.ac")

MAC_LIBS = ('       LIBS="$LIBS -framework Carbon -framework CoreFoundation '
            '-framework CoreMIDI -framework AudioUnit -framework AudioToolbox '
            '-framework ApplicationServices -framework AppKit -framework IOKit "')

REPLACEMENT = '''       dnl iOS reports the same *-*-darwin* signature as macOS, so the only
       dnl reliable discriminator is the -target the compiler was given.
       dnl Carbon, AppKit, ApplicationServices and IOKit are macOS-only; on iOS
       dnl they make every configure link probe fail.
       case "$CFLAGS$CXXFLAGS" in
         *-target\\ arm64-apple-ios*|*apple-ios*)
           iphoneos=1
           AC_DEFINE(IPHONEOS, 1, [Compiling for iOS])
           LIBS="$LIBS -framework CoreFoundation -framework CoreMIDI -framework AudioToolbox -framework UIKit "
           ;;
         *)
           LIBS="$LIBS -framework Carbon -framework CoreFoundation -framework CoreMIDI -framework AudioUnit -framework AudioToolbox -framework ApplicationServices -framework AppKit -framework IOKit "
           ;;
       esac'''

METAL_ANCHOR = 'if test "x$have_metal" = "xyes"; then'
METAL_NEW = '''dnl Metal itself exists on iOS, so this probe succeeds -- but DOSBox-X's Metal
dnl backend (output_metal.mm) is AppKit-based, and AppKit is macOS-only. Left
dnl enabled, C_METAL compiles the callers and the link then fails on
dnl OUTPUT_Metal_Select and friends. This project renders through Game Link
dnl into a buffer anyway and never uses a window backend.
case "$CFLAGS$CXXFLAGS" in
  *apple-ios*) have_metal=no ;;
esac

if test "x$have_metal" = "xyes"; then'''

with open(path) as f:
    text = f.read()

if "Compiling for iOS" in text:
    print("    configure.ac: already patched")
elif MAC_LIBS not in text:
    sys.exit("error: framework anchor not found in configure.ac - has upstream moved?")
else:
    text = text.replace(MAC_LIBS, REPLACEMENT, 1)
    if METAL_ANCHOR in text:
        text = text.replace(METAL_ANCHOR, METAL_NEW, 1)
    with open(path, "w") as f:
        f.write(text)
    print("    configure.ac: patched (frameworks + metal)")
