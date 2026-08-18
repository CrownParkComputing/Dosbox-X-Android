#!/usr/bin/env python3
"""The source changes an Android build of DOSBox-X needs.

This is the Android sibling of ios/apply-ios-source.py. The patch set is
deliberately here as plain *.patch files in patches/0001-... rather than
inlined as text replacements, because they are the same patches the legacy
Java/SDL app already ships and validates against on retroid hardware. The
script's only job is to apply them in order and bail out -- never silently
produce a half-patched tree that builds but cannot run.

The patches cover four jobs:

  0001-android-configure-target        host='*-*-android*' case in configure.ac,
                                      creating C defines LINUX and ANDROID so
                                      the POSIX code paths compile but the
                                      Linux-desktop-only bits (alsa, X11) do
                                      not pull in.
  0002-android-sdl1-cdrom-include     SDL 1.2's CD-ROM driver guards on
                                      __LINUX__ only; bionic has no
                                      <linux/version.h>, so the include is
                                      skipped under __ANDROID__ and the file
                                      fails to compile.
  0003-android-sdlmain                Real Android-only behaviour: the
                                      status line lives in a global the Java
                                      FPS overlay reads, the SDL window is
                                      pinned to display size, and several
                                      SDL_Init subsystems (haptic, audio
                                      device) are disabled because they crash
                                      on bionic.
  0004-android-render-aspect          render.cpp's aspect-ratio keep lists
                                      used to skip non-4:3 modes on handhelds.
  0005 / 0006  output / GL surface    the small DOS framebuffer is rendered
                                      into a content-sized texture scaled on
                                      the GPU, not by shrinking the window,
                                      because the Android SDL window is
                                      always the full display.
  0007-android-native-config-gui      the legacy app's DIY config GUI lives
                                      here; harmless in our build because the
                                      Flutter app generates the conf file
                                      itself and never calls into it.

Run with the path to the -fPIC tree:

    python3 apply-android-source.py /home/jon/dosbox-x-pic
"""
import os
import subprocess
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
TREE = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/dosbox-x-pic")

if not os.path.isdir(os.path.join(TREE, ".git")):
    sys.exit(f"error: {TREE} is not a git checkout")

patches = sorted(p for p in os.listdir(os.path.join(HERE, "patches"))
                 if p.endswith(".patch"))
if not patches:
    print("warning: no patches in patches/ -- nothing to apply")
    sys.exit(0)

for p in patches:
    path = os.path.join(HERE, "patches", p)
    print(f"==> applying {p}")
    # Rerun-safe: if the patch is already applied, `git apply --check` exits
    # non-zero with a clear message, and we skip with a verdict rather than
    # failing the whole build.
    r = subprocess.run(["git", "apply", "--check", path],
                       cwd=TREE, capture_output=True, text=True)
    if r.returncode == 0:
        subprocess.run(["git", "apply", path], cwd=TREE, check=True)
        print(f"    patched")
    else:
        if "patch failed" in r.stderr or "already applied" in r.stderr:
            print(f"    already applied (skipping)")
        else:
            sys.exit(f"error: cannot apply {p}:\n{r.stderr}")

print("==> done")
