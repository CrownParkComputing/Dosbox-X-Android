#!/usr/bin/env python3
"""The source changes an iOS build of DOSBox-X needs.

MACOSX stays defined for iOS -- the source uses it for Darwin-common things
(paths, endianness, dyld) that are equally true there -- so the places that mean
*macOS specifically* have to say so. Every edit below is keyed on IPHONEOS,
which the configure.ac patch defines, so macOS behaviour is untouched.

Anchored on text and idempotent, for the same reason as apply-bridge-hook.py: a
unified diff carries line numbers that go stale on every upstream pull and fails
with a rejected hunk rather than a useful message.
"""
import os
import sys

TREE = sys.argv[1] if len(sys.argv) > 1 else "."

# menu_macos.mm compiles to nothing on iOS, so the macOS UI helpers its callers
# reference have to come from somewhere. They are appended to the same file --
# inside the IPHONEOS branch -- so the stubs live next to the real ones and
# cannot drift apart silently.
MM_STUBS = """
#else  /* IPHONEOS */

/* iOS stubs. menu_macos.mm is the macOS menu bar, Cocoa dialogs, the Touch Bar
   and the dock menu -- none of which exist on iOS, and none of which a Flutter
   host wants: it draws its own UI. Callers reference these unconditionally
   under MACOSX, so they must exist to link. */
#include <string>
#include "menu.h"
/* ScreenSizeInfo lives here, not in menu.h. */
#include "sdlmain.h"

bool has_touch_bar_support = false;
bool macosx_detect_nstouchbar(void) { return false; }
void macosx_reload_touchbar(void) { }
void macosx_init_touchbar(void) { }
void macosx_init_dock_menu(void) { }
void macosx_alert(const char *, const char *) { }
/* 1 = yes. Nothing can be asked without a dialog, so decline rather than
   silently confirm something the user never saw. */
int macosx_yesno(const char *, const char *) { return 0; }
int macosx_yesnocancel(const char *, const char *) { return 0; }
std::string macosx_prompt_folder(const char *) { return std::string(); }
bool IME_GetEnable(void) { return false; }
void IME_SetEnable(int) { }

/* The window belongs to Flutter, not to us, so there is no NSWindow to measure.
   Left untouched: callers treat an unfilled ScreenSizeInfo as "unknown". */
void macosx_GetWindowDPI(ScreenSizeInfo &) { }

/* The Cocoa menu bar. menu.cpp declares these unconditionally under MACOSX and
   calls them while building the native menu, which iOS does not have. */
void  sdl_hax_nsMenuItemUpdateFromItem(void *, DOSBoxMenu::item &) { }
void  sdl_hax_nsMenuItemSetTag(void *, unsigned int) { }
void  sdl_hax_nsMenuItemSetSubmenu(void *, void *) { }
void  sdl_hax_nsMenuAddItem(void *, void *) { }
void *sdl_hax_nsMenuAllocSeparator(void) { return NULL; }
void *sdl_hax_nsMenuAlloc(const char *) { return NULL; }
void  sdl_hax_nsMenuRelease(void *) { }
void *sdl_hax_nsMenuItemAlloc(const char *) { return NULL; }
void  sdl_hax_nsMenuItemRelease(void *) { }
void  sdl_hax_nsMenuAddApplicationMenu(void *) { }
void  sdl_hax_macosx_setmenu(void *) { }
void  menu_macosx_set_menuobj(DOSBoxMenu *) { }

/* Window-manager niceties (always-on-top, capture exclusion, matching the
   window to a monitor). All of them act on an NSWindow this process does not
   own -- the window belongs to Flutter. */
void  sdl1_hax_set_topmost(unsigned char) { }
void  MacOSEnableWindowCapture(unsigned int) { }
void  qz_set_match_monitor_cb(void) { }
void  SetAlpha(double) { }
"""


EDITS = [
    # SDL1's macOS CD-ROM implementation is Carbon-based, and Carbon is
    # macOS-only. An iOS device has no CD drive; the file already has a
    # SDL_CDROM_DUMMY fallback, which is exactly right, so iOS falls to it.
    ("src/dos/cdrom.cpp",
     "#elif defined(MACOSX)\n#define SDL_CDROM_MACOSX",
     "#elif defined(MACOSX) && !defined(IPHONEOS)\n"
     "/* iOS has no CD drive and this path is Carbon-based (macOS only), so\n"
     "   iOS falls through to SDL_CDROM_DUMMY below. */\n"
     "#define SDL_CDROM_MACOSX",
     1),

    # Carbon again, for the key mapper.
    ("src/gui/sdl_mapper.cpp",
     "#if defined(MACOSX)\n#include <Carbon/Carbon.h>",
     "#if defined(MACOSX) && !defined(IPHONEOS)  /* Carbon is macOS-only */\n"
     "#include <Carbon/Carbon.h>",
     1),

    # CoreAudio's DLS synth and default-output units do not exist on iOS
    # (kAudioUnitSubType_DLSSynth, kAudioUnitSubType_DefaultOutput,
    # kMusicDeviceParam_Volume are all macOS-only). CoreMIDI goes with it: the
    # remaining #elif chain leaves iOS with no MIDI backend, which is honest --
    # there is no audio backend on any platform yet (docs/NATIVE_BUILD.md).
    ("src/gui/midi.cpp",
     '#if defined(MACOSX)\n\n#include "midi_coremidi.h"\n#include "midi_coreaudio.h"',
     '#if defined(MACOSX) && !defined(IPHONEOS)\n\n'
     '/* CoreAudio\'s DLS synth and default output unit are macOS-only. */\n'
     '#include "midi_coremidi.h"\n#include "midi_coreaudio.h"',
     1),

    # menu_macos.mm is the macOS menu bar, which a Flutter host has no use for.
    # It also cannot compile here: it includes SDL_syswm.h, which pulls in
    # UIKit for an iOS SDL build, and automake compiles .mm through OBJCXX,
    # whose flags do not carry our -isysroot. Compiling to nothing is both the
    # simplest fix and the right one.
    ("src/gui/menu_macos.mm",
     '#include "config.h"',
     '#include "config.h"\n\n'
     '/* The macOS menu bar is meaningless in a Flutter host, and this file\n'
     '   cannot compile for iOS anyway (SDL_syswm.h pulls in UIKit, and .mm\n'
     '   goes through OBJCXX, whose flags lack our -isysroot). */\n'
     '#if !defined(IPHONEOS)',
     1),
    ("src/gui/menu_macos.mm", "__EOF_GUARD__", "", 0),   # handled below

    # Callers reference these unconditionally under MACOSX, so blanking the
    # file leaves them undefined at link. Stubs keep the build honest: the
    # behaviour they implement (Cocoa dialogs, the Touch Bar, the dock menu,
    # IME) has no meaning in a Flutter host, which draws its own UI.
    ("src/gui/menu_stub_ios.h", "__STUBS__", "", 0),

    # Shelling out to open a URL or relaunch: iOS marks system() unavailable
    # outright and there is no shell to reach. Callers already handle failure.
    ("src/gui/sdl_gui.cpp",
     '#else\n        system((exepath+" "+para+ " &").c_str());\n#endif',
     '#elif !defined(IPHONEOS)  /* no system() on iOS */\n'
     '        system((exepath+" "+para+ " &").c_str());\n#endif',
     2),
    ("src/gui/sdl_gui.cpp",
     '#elif defined(MACOSX)\n            system(("open "+url).c_str());',
     '#elif defined(MACOSX) && !defined(IPHONEOS)\n'
     '            system(("open "+url).c_str());',
     1),
    ("src/gui/sdl_gui.cpp",
     '#elif defined(LINUX)\n            system(("xdg-open "+url).c_str());',
     '#elif defined(LINUX) && !defined(IPHONEOS)\n'
     '            system(("xdg-open "+url).c_str());',
     1),
    # Six more shell-outs, all the same shape: a printer/serial "run this
    # program on the captured file" hook. iOS has neither system() nor a shell.
    # The iOS branch still assigns `fail`, so the caller reports the failure it
    # would report for any other unrunnable action rather than reading an
    # uninitialised value.
    ("src/hardware/serialport/serialfile.cpp",
     '#else\n        fail=system((action+" "+filename).c_str())!=0;',
     '#elif defined(IPHONEOS)\n        fail=true;  /* no system() on iOS */\n'
     '#else\n        fail=system((action+" "+filename).c_str())!=0;',
     1),
    ("src/hardware/serialport/serialfile.cpp",
     '#else\n            fail=system((action+" "+filename).c_str())!=0;',
     '#elif defined(IPHONEOS)\n            fail=true;  /* no system() on iOS */\n'
     '#else\n            fail=system((action+" "+filename).c_str())!=0;',
     1),
    ("src/hardware/parport/printer.cpp",
     '#else\n        fail=system((action+" "+fname).c_str())!=0;',
     '#elif defined(IPHONEOS)\n        fail=true;  /* no system() on iOS */\n'
     '#else\n        fail=system((action+" "+fname).c_str())!=0;',
     1),
    ("src/hardware/parport/printer.cpp",
     '#else\n            fail=system((action+" "+fname).c_str())!=0;',
     '#elif defined(IPHONEOS)\n            fail=true;  /* no system() on iOS */\n'
     '#else\n            fail=system((action+" "+fname).c_str())!=0;',
     1),
    ("src/hardware/parport/filelpt.cpp",
     '#else\n        fail=system((action+" "+name).c_str())!=0;',
     '#elif defined(IPHONEOS)\n        fail=true;  /* no system() on iOS */\n'
     '#else\n        fail=system((action+" "+name).c_str())!=0;',
     1),
    ("src/hardware/parport/filelpt.cpp",
     '#else\n            fail=system((action+" "+name).c_str())!=0;',
     '#elif defined(IPHONEOS)\n            fail=true;  /* no system() on iOS */\n'
     '#else\n            fail=system((action+" "+name).c_str())!=0;',
     1),

    # Game Link publishes frames through POSIX shared memory so an external
    # client (Grid Cartographer) can attach. iOS forbids that: shm_open fails
    # with EPERM. And because DOSBox-X allocates the guest's RAM *inside* this
    # mapping (memory.cpp: MemBase = GameLink::AllocRAM), the failure does not
    # surface as "no shared memory" -- it surfaces as
    #   E_Exit: Can't allocate main memory of 32768 KB
    # which reads like the device is out of RAM.
    #
    # A private anonymous mapping is equivalent here and leaves every
    # downstream path untouched: nothing can attach to it on iOS regardless,
    # and this app reads finished frames through the bridge hook, not through
    # the shared block.
    ("src/gamelink/gamelink.cpp",
     "#else // WIN32\n\n\tg_mmap_handle = shm_open( GAMELINK_MMAP_NAME, O_CREAT",
     """#else // WIN32

#if defined(IPHONEOS)
\t/* iOS: no POSIX shared memory. See the note in apply-ios-source.py. */
\tg_mmap_handle = -1;
\tg_p_shared_memory = reinterpret_cast< GameLink::sSharedMemoryMap_R4* >(
\t\tmmap(nullptr, memory_map_size, PROT_READ | PROT_WRITE,
\t\t     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
\t);
\tif ( g_p_shared_memory == MAP_FAILED ) {
\t\tg_p_shared_memory = NULL;
\t\treturn 0;
\t}
\treturn 1;
#endif

\tg_mmap_handle = shm_open( GAMELINK_MMAP_NAME, O_CREAT""",
     1),

    # The Metal output backend is AppKit-based, and AppKit is macOS-only (iOS
    # has UIKit). Irrelevant here regardless: this project renders through the
    # Game Link output into a buffer, never to a window.
    ("src/output/output_metal.mm",
     "#if defined(MACOSX) && C_METAL",
     "#if defined(MACOSX) && !defined(IPHONEOS) && C_METAL  /* AppKit is macOS-only */",
     1),

    # RetroWave drives a real external OPL2 board over a serial port. Its
    # Darwin path uses IOKit's serial extensions, which are macOS-only
    # ("'IOKit/serial/ioss.h' file not found"). These two files are plain C in
    # a vendored library and do not include config.h, so IPHONEOS is not
    # visible here -- Apple's own TargetConditionals is the right discriminator.
    # An iPad cannot have such a board attached anyway.
    ("src/hardware/RetroWaveLib/Platform/POSIX_SerialPort.h",
     "#ifdef __APPLE__\n#include <IOKit/serial/ioss.h>\n#endif",
     "#ifdef __APPLE__\n"
     "#include <TargetConditionals.h>\n"
     "#if !TARGET_OS_IPHONE  /* IOKit serial is macOS-only */\n"
     "#include <IOKit/serial/ioss.h>\n"
     "#endif\n"
     "#endif",
     1),
    ("src/hardware/RetroWaveLib/Platform/POSIX_SerialPort.c",
     "#ifdef __APPLE__\n\tint speed = 2000000;",
     "#if defined(__APPLE__) && !TARGET_OS_IPHONE\n\tint speed = 2000000;",
     1),

    ("src/dos/dos_programs.cpp",
     '#if defined(LINUX) || defined(MACOSX)\n        ret=system(((open?',
     '#if (defined(LINUX) || defined(MACOSX)) && !defined(IPHONEOS)\n'
     '        ret=system(((open?',
     1),
    ("src/gui/menu_callback.cpp",
     '#elif defined(MACOSX)\n      int ret = system(("open "+url).c_str());',
     '#elif defined(MACOSX) && !defined(IPHONEOS)\n'
     '      int ret = system(("open "+url).c_str());',
     1),
]

for rel, old, new, count in EDITS:
    if count == 0:
        continue
    path = os.path.join(TREE, rel)
    with open(path) as f:
        text = f.read()
    # Idempotence is decided by the replacement text being present verbatim,
    # not by hunting for a marker: the RetroWave edit keys on TARGET_OS_IPHONE
    # rather than IPHONEOS (that file cannot see config.h), so a marker check
    # for IPHONEOS declared an already-patched tree unpatched and then failed
    # on the missing anchor.
    if new and text.count(new) >= count:
        print(f"    {rel}: already patched")
        continue
    found = text.count(old)
    if found < count:
        sys.exit(f"error: expected {count}x anchor in {rel}, found {found} "
                 "- has upstream moved?")
    with open(path, "w") as f:
        f.write(text.replace(old, new, count))
    print(f"    {rel}: patched ({count})")

# menu_macos.mm needs its opening guard closed at end of file.
mm = os.path.join(TREE, "src/gui/menu_macos.mm")
with open(mm) as f:
    text = f.read()
if "#if !defined(IPHONEOS)" in text and "iOS stubs" not in text:
    with open(mm, "w") as f:
        f.write(text.rstrip() + "\n" + MM_STUBS + "\n#endif /* !IPHONEOS */\n")
    print("    src/gui/menu_macos.mm: closed guard + iOS stubs")
