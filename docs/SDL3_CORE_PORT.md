# Porting DOSBox-X to SDL3 — our branch

Decision (2026-09-01): DOSBox-X is ported to SDL3 on our own branch, rather than
sealing SDL2 inside the core. This document is the strategy.

## 0. Working tree

**`~/dosbox-x-sdl3`** — fresh clone of upstream `master` @ `88254b18a`,
`AC_INIT(dosbox-x,2026.08.31)`. Remote `origin` renamed to **`upstream`**; our
work is on branch **`sdl3`**.

The previous tree (`~/dosbox-x-pic` @ `784240ad`, 2026.08.02) is superseded: its
origin pointed at `~/Downloads/dosbox-x-src`, which no longer exists, and it has
the Android patch series applied in place. Keep it only as a reference for the
old patch state; do not build from it.

Upstream ships **only `master`** now — the `latest` branch in the old tree came
from that deleted local repo.

DOSBox-X **vendors its own SDL** in `vs/sdl` (1.2) and `vs/sdl2`. There is no
`vs/sdl3`. This is the answer to the `android/build.sh` dependency on prebuilt
SDL2 symlinked out of the retired Java app — the source is already in the tree.

### 0.1 TRAP: a non-TTY stdin makes DOSBox-X prompt for a folder

**Symptom:** the core starts, `dosbox_core_is_running()` returns 1, and no frame
is ever published. The log stops after the early-init lines and never reaches
`CONFIG: Loaded config file`. On a desktop with a display you instead get a
**folder-picker dialog popping up**; headless you get nothing at all and the
process blocks forever.

**Cause** — `src/gui/sdlmain.cpp:8725`:

```c
control->opt_promptfolder = ((!isatty(0) && !default_config) || ...) ? 1 : 0;
```

**When stdin is not a TTY, DOSBox-X decides to prompt for its working
directory.** `main()` then calls `tinyfd_selectFolderDialog()` (sdlmain.cpp:8799),
which with no GUI falls back to reading a line from stdin with `fgets` — and
blocks. Backtrace of the stall:

```
#7  tinyfd_selectFolderDialog (...) at tinyfiledialogs.c:7921
#8  main (...) at sdlmain.cpp:8799
#9  mainloop_thread(void*)
```

This is perverse but deliberate: interactive runs are assumed to have a config,
automated ones are assumed to need asking. It means **every non-interactive
context hits it** — pipes, `timeout`, CI, a test harness, and any embedded use
where the engine is not attached to a terminal. It stayed hidden because
`check-core.sh` was historically run by hand from an interactive shell.

**Fix — put this in every generated conf:**

```ini
[dosbox]
working directory option=noprompt
```

`conf_builder` must emit this unconditionally. On Android and iOS there is no
stdin *and* no tinyfd, so the failure mode there is a silent hang with no
diagnostic whatsoever.

Android patch 0003 exists partly to suppress tinyfd; the conf setting is the
better fix because it needs no patch and cannot drift against upstream.

## 1. The size of the problem, measured

Measured on the fresh 2026.08.31 tree; the older tree gave 3088/562/506, so these
numbers are stable across a month of upstream churn.

| Metric | Count |
|---|---:|
| Files referencing SDL | 93 |
| `SDL_*` call sites | 3074 |
| Distinct `SDL_*` identifiers | 559 |
| Existing `C_SDL2` conditional sites | 505 |

Concentration, by call sites:

| File | Lines | SDL sites |
|---|---:|---:|
| `src/gui/sdlmain.cpp` | 10819 | 537 |
| `src/gui/sdl_mapper.cpp` | 6114 | 356 |
| `src/hardware/imfc.cpp` | — | 137 |
| `src/gui/sdl_gui.cpp` | — | 90 |
| `src/gui/sdl_ttf.c` | — | 87 |
| `src/output/output_ttf.cpp` | 1545 | 86 |
| `src/output/output_surface.cpp` | 811 | 69 |
| `src/output/output_opengl.cpp` | 1169 | 56 |
| `src/libs/gui_tk/gui_tk.cpp` | — | 56 |

Two files carry ~29% of the total.

## 2. The lever: port what we build, not what exists

Our target is a **headless core for Android and iOS**: gamelink output, no window,
no DOSBox-X menu, audio through our own AAudio/CoreAudio backends, DOS + Win3.x
only. A large share of the SDL-heavy code is *not compiled into that build at all*
— and much of the rest we are deliberately deleting.

| File | SDL sites | In our build? |
|---|---:|---|
| `output_direct3d.cpp`, `output_direct3d11.cpp` | — | No — Windows only |
| `output_opengl.cpp` | 56 | No — headless |
| `output_surface.cpp` | 69 | No — headless |
| `output_ttf.cpp` + `sdl_ttf.c` | 173 | No — TTF output unused |
| `sdl_gui.cpp` + `gui_tk.cpp` + `menu.cpp` | 167 | **No — this is the menu we are stripping for the RMU** |
| `voodoo_opengl.cpp`, `voodoo_vogl.cpp` | 60 | No — 3D/Voodoo is out of scope (DOS + Win3.x) |
| `output_gamelink.cpp` | — | **Yes — this is our output** |
| `sdlmain.cpp` | 537 | Partially — most of it is window/menu code we do not reach |
| `sdl_mapper.cpp` | 356 | Yes — but its GUI and joystick halves are droppable |

### 2.1 Removing the DOSBox-X GUI is a lever on the port, not just a UI change

The original GUI is being replaced by our ImGui RMU. That decision was made for
UI reasons, but it pays for itself twice, because the GUI is one of the largest
SDL consumers in the tree:

| File | Lines | SDL sites |
|---|---:|---:|
| `src/gui/sdl_gui.cpp` | 4101 | 90 |
| `src/gui/sdl_ttf.c` | 2106 | 87 |
| `src/output/output_ttf.cpp` | 1545 | 86 |
| `src/libs/gui_tk/gui_tk.cpp` | 2938 | 56 |
| `src/gui/menu_callback.cpp` | 3952 | 12 |
| `src/gui/menu.cpp` | 3663 | 21 |
| **Total** | **18306** | **352** |

Plus `menu_macos.mm`, `include/menu.h`, `include/menudef.h`.

That is **~18.3k lines and 352 SDL call sites (11% of the tree's total) deleted
rather than ported.** Add the other out-of-scope output backends
(`output_opengl` 56, `output_surface` 69) and the Voodoo GL paths
(`voodoo_opengl` 36, `voodoo_vogl` 24) and roughly **525 of 3088 SDL sites — a
sixth of the problem — disappear before any porting starts.**

The catch to plan for: `DOSBOXMENU_TYPE` is referenced well outside the menu
files — `sdlmain.cpp` (35), `sdl_mapper.cpp` (10), `shell.cpp` (8),
`output_ttf.cpp` (10), `output_opengl.cpp` (9), `output_surface.cpp` (7). So
removing the menu is not `rm` on a few files; it means compiling with
`DOSBOXMENU_NULL` and cleaning up the call sites that leak into the rest of the
core. Patch 0003 already suppresses part of this and is the right place to grow.

**So the port is scoped to the object set our headless build actually links.**
Everything else keeps its existing `C_SDL2` path untouched, which is also what
keeps upstream merges tractable — and we have signed up for regular upstream
merges by asking for the latest core.

**First task of the port is therefore not code, it is a list**: derive the exact
compiled-object set from the headless build, and port against that list. Guessing
this list is how a port of this shape turns into a rewrite.

## 2.2 CORRECTION: upstream already has SDL3 scaffolding

An earlier draft of this document said "there is no upstream SDL3 effort to
ride". **That was wrong.** DOSBox-X 2026.08.31 ships:

- `--enable-sdl3` in `configure.ac`, with `AM_PATH_SDL3` in `acinclude.m4`
  (pkg-config based — SDL3 has no `sdl3-config`).
- A `C_SDL3` hook in `include/dosbox.h` carrying upstream's own comment:

```c
/* HACK: To make SDL3 porting easier, define SDL2 to prevent SDL1 code from compiling */
#if defined(C_SDL3) && !defined(C_SDL2)
# define C_SDL2 1
#endif
```

That is **exactly the strategy in §3** — keep the SDL2-era code paths compiling
and shim SDL3 underneath — so it is upstream-sanctioned rather than a private
fork idea, and it materially lowers the merge risk this document warned about.

**But the scaffolding is inert as shipped**, and our branch fixes both parts:

1. `configure.ac` sets `SDL_STRING`/`LIBS`/`CPPFLAGS` for SDL3 but **never does
   `AC_DEFINE(C_SDL3)`**, so `C_SDL3` was never defined and the hack above never
   fired — an `--enable-sdl3` build was indistinguishable from SDL1 in source.
   Added `AC_DEFINE(C_SDL3,1,...)`.
2. It demands `SDL3_VERSION=3.5.0`. Distro SDL3 here is **3.4.12**, so the check
   could never pass. Lowered to `3.2.0` (first stable SDL3).

With those two changes `./configure --enable-sdl3` succeeds and `config.h` gets
`#define C_SDL3 1`. Header resolution needs no shim: `pkg-config sdl3 --cflags`
yields `-I/usr/include/SDL3`, so the tree's `#include "SDL.h"` resolves to
SDL3's own header natively.

## 3. Strategy: a shim for the renames, hands for the semantics

SDL3 changes fall into two very different piles.

> **REVISED 2026-09-01: Pile 1 is free.** SDL3 ships
> `<SDL3/SDL_oldnames.h>` with **~1032 SDL2→SDL3 mappings**, gated on
> `SDL_ENABLE_OLD_NAMES`. It already covers `SDL_FreeSurface`, `SDL_CondWait`,
> `SDL_CreateCond`, `SDL_AllocPalette`, `SDL_RenderCopy`, `SDL_UpperBlit` and
> the rest of the table below. **Do not hand-roll a rename table** — a local
> `#define` only shadows a better, upstream-maintained one.
>
> Note the design: *without* the flag those spellings resolve to
> `SDL_FreeSurface_renamed_SDL_DestroySurface`, i.e. a compile error that names
> its own fix. That is the mechanism for finding genuinely-changed APIs instead
> of silently mistranslating them.
>
> Our branch sets `-DSDL_ENABLE_OLD_NAMES=1` in `configure.ac`. The table below
> is kept only as a reference for what that flag is doing.

**Pile 1 — mechanical renames** (the large majority of the 562 identifiers):

| SDL2 | SDL3 |
|---|---|
| `SDL_CreateRGBSurface` | `SDL_CreateSurface` |
| `SDL_FreeSurface` | `SDL_DestroySurface` |
| `SDL_AllocPalette` / `SDL_FreePalette` | `SDL_CreatePalette` / `SDL_DestroyPalette` |
| `SDL_CondWait` / `SDL_CondSignal` | `SDL_WaitCondition` / `SDL_SignalCondition` |
| `SDL_CreateCond` / `SDL_DestroyCond` | `SDL_CreateCondition` / `SDL_DestroyCondition` |
| `SDL_RenderCopy` | `SDL_RenderTexture` |
| `SDL_UpperBlit` / `SDL_UpperBlitScaled` | `SDL_BlitSurface` / `SDL_BlitSurfaceScaled` |
| `SDL_SetRelativeMouseMode` | `SDL_SetWindowRelativeMouseMode` |
| `SDL_WINDOWEVENT_*` | `SDL_EVENT_WINDOW_*` |

These are handled by an in-tree `include/sdl3_compat.h` plus a **table-driven
rename pass**, with the compiler as the gate. No judgement required, so it should
not consume judgement.

**Pile 2 — genuine semantic changes.** These must be hand-ported and are where the
real risk lives:

- **Audio.** SDL3's model is streams, not callbacks — a rewrite, not a rename.
  *Largely moot for us*: our AAudio/CoreAudio/ALSA backends already replace SDL
  audio via weak-symbol hooks.
- **Events.** `SDL_Event` field renames, `SDL_Keysym` removed, window events
  promoted to top-level event types. This matters directly because the bridge
  **synthesises `SDL_Event`s** to inject input.
- **Joystick.** Index-based (`SDL_JoystickOpen(index)`) became instance-ID based
  with a different enumeration model. Concentrated in `sdl_mapper.cpp`.
- **Surfaces / palettes.** `SDL_Surface::format` is now a format enum, not a
  `SDL_PixelFormat*` struct. Touches the gamelink path.
- **`SDL_GetWindowWMInfo` is gone**, replaced by the properties API. Used in
  `sdlmain_linux.cpp` — but headless, so likely excluded.
- **Types.** `SDL_GetTicks()` returns `Uint64`; bool return conventions changed
  (`0 == success` became `true == success` in many APIs) — **this one is silent
  and dangerous**, because inverted success checks still compile.

That last item deserves its own review pass. A rename that compiles is safe; an
inverted return value compiles *and* runs, wrongly.

## 4. The validation oracle — the part that de-risks this

Do not port blind. Build the same commit three ways:

- **(a) stock SDL2** — today's behaviour, the control.
- **(b) SDL2 API on `sdl2-compat` over SDL3** — [libsdl-org/sdl2-compat](https://github.com/libsdl-org/sdl2-compat)
  is an official, production layer that implements the SDL2 ABI on SDL3. Fedora
  and Ubuntu now ship it to run *all* SDL2 apps on SDL3.
- **(c) our native SDL3 branch** — the port.

**(b) gives a known-good "DOSBox-X running on SDL3" reference before our port
compiles a single file.** It separates two failure modes that are otherwise
impossible to tell apart:

- (a) works, (b) fails → the problem is SDL3 itself, or DOSBox-X relying on SDL2
  behaviour SDL3 dropped. **Not our bug**, and worth reporting upstream.
- (b) works, (c) fails → the problem is our port. Diffable, and bounded.

This turns a blind port into a differential one, and it matches the project's
existing oracle discipline (`check-core.sh` as a host-side gate rather than a
device round-trip).

## 5. Branch and merge discipline

- Fresh clone of upstream (`~/dosbox-x-pic` is at `2026.08.02`; take current
  `latest`). Keep `upstream` as a remote — regular merges are now a standing cost.
- Our work on branch **`sdl3`**.
- **Additive, never destructive**: introduce `C_SDL3` beside `C_SDL2`, never in
  place of it. Deleting the SDL2 paths would make every upstream merge a conflict
  in `sdlmain.cpp`, the worst file in the tree to conflict in.
- Keep the port confined to the in-scope object list from §2. Files outside it
  keep their SDL2 paths verbatim and merge cleanly.

## 6. Phases

**P0 — baseline. DONE for the host (2026-09-01).**
Fresh upstream clone, branch `sdl3`, `-fPIC` engine tree, bridge + ALSA backend
linked into `libdosboxcore.so`, full ABI exported.

Results on `~/dosbox-x-sdl3` @ 2026.08.31:

- The **bridge hook applies cleanly** to a month-newer upstream (+93 lines across
  `output_gamelink.cpp`, `sdlmain.cpp` ×2, `mixer.cpp`). No drift breakage.
- Gate green: gamelink initialised (22 MB shared memory), 640x480 frame,
  **60701 / 307200 non-black px** — identical to the previously recorded value —
  frame counter advancing, ALSA backend running.
- **10/10 PASS, 10/10 `shutdown: clean`.**

### P0.1 In-process restart — "one-shot core" looks WRONG, and that matters for iOS

`check-cycles.{c,sh}` (new) does N start/stop cycles **inside one process**,
which is the iOS question. iOS cannot spawn a process per session, so "quit to
library" depends entirely on this.

Result: **cycle 1 passes with a clean stop; cycle 2 fails.** Eight blockers found
and seven fixed, all of ONE class — **asymmetric teardown: a global survives
while the state it depends on is wiped.** None architectural.

| # | Blocker | Root cause | Fix | State |
|---|---|---|---|---|
| 1 | SIGSEGV `GFX_LogSDLState` (sdlmain.cpp:2121) | `sdl.surface` freed, not nulled; crashes **while logging** | NULL guard | fixed |
| 2 | `assert(test == NULL)` `CPU_PreInit` (cpu.cpp) | `delete test;` without `test = NULL` | 1 line ×3 (cpu, glide, pcspeaker) | fixed |
| 3 | `No such item 'mapper_cycauto'` | `CPU::inited` static survives teardown → skips `MAPPER_AddHandler`, which is what ALLOCATES the item; menu *is* cleared | `CPU::reset_inited()` in `CPU_ShutDown` | fixed |
| 4 | (same, via `MAPPER_AddHandler` dedupe) | handler outlives its menu item | recreate item if missing | fixed (defensive — `handlergroup` is in fact cleared) |
| 5 | SIGSEGV `CBind::GetModifierText` (sdl_mapper.cpp:3230) | `MAPPER_Shutdown()` deletes `events[]` but never nulls `mod_event[8]`, which holds copies; call site only NULL-checks | null `mod_event[]` in `MAPPER_Shutdown` | fixed |
| 6 | `No such item 'mapper_incsize'` | `has_GUI_StartUp` one-shot flag survives; `GUI_StartUp()` registers the handlers that allocate items | reset flag at shutdown | fixed |
| 7 | `get_item() attempt to read unallocated item` | stale handles into a cleared menu | `RETRODOSBOX_MENU_SINK`: lookups return a scratch item instead of `E_Exit` | fixed (stopgap) |
| 8 | `displaylist_append() item already in use` | menu display lists rebuilt over items already linked | — | **OPEN** |

On #2: **17 of the 21 modules using the `static X* test` singleton pattern
already null it correctly.** Only `cpu.cpp`, `glide.cpp` and `pcspeaker.cpp` did
not. That distribution is the tell — upstream evidently *intends* these modules
to be re-initialisable; these three are simply bugs.

**Conclusion: "DOSBox-X is a one-shot core" is not a design property.** It is a
cluster of missing resets, most of them one line. Every fix so far has been
mechanical and none required changing how the emulator works.

**But the remaining blockers are all in the menu subsystem**, and that is the
signal for what to do next: stop making the menu restart-safe and **remove it**.
Blockers 3, 4, 6, 7 and 8 are all menu bookkeeping for a menu this build never
draws. The sink in #7 is a stopgap; the real fix is the GUI strip in §2.1, which
is planned work rather than new work. **Pull the menu removal forward ahead of
the SDL3 port** — it is on the critical path for iOS, not just a UI task.

**Not proven yet:** whether N/N clean is reachable. Until `check-cycles.sh` is
green, the **Android process-per-session model stays** and iOS "quit to library"
is unconfirmed. `dosbox_core_set_shared_frame` remains the Android fallback and
needs no changes.

Still outstanding in P0:
- Build **SDL2 and libpng from the vendored `vs/sdl2`** rather than symlinking
  prebuilts out of the retired Java app at `~/AndroidStudioProjects/DosBoxX/`.
- **In-process** start/stop/start repetition. The 10/10 above is ten separate
  processes doing one cycle each, which is *not* the iOS question. iOS cannot
  spawn a process per session, so what must be proven is N cycles inside one
  process. `check-core.c` does one cycle; a repeat harness needs writing
  (retro-x86 has `core-twice.c` / `core-again.c` as the model).

**P1 — the list.** Derive the exact compiled-object set of the headless build.
Publish it in this doc. Everything downstream is scoped to it.

**P2 — scaffolding.** `C_SDL3` config plumbing, SDL3 detection, `sdl3_compat.h`
covering Pile 1. Nothing ports yet; the tree still builds SDL2.

**P3 — mechanical pass.** Table-driven renames across in-scope files. Gate: it
compiles against SDL3.

**P4 — semantic pass**, in dependency order: threads/timing → events (bridge
injection path) → surfaces/gamelink → mouse/keyboard → joystick/mapper. Audio is
bypassed by our backends. Includes the dedicated **inverted-return-value review**.

**P5 — differential validation.** Build (a)/(b)/(c) per §4. Gate: (c) matches (b)
on headless boot, frame advance, input injection, and 20x clean start/stop.

**P6 — integrate.** Bridge + reduced patch series on top. Patches 0004–0006
(SDL2 window content scale) and 0007 (native config GUI) are dropped; the
`SDL_DBX_*` SDL2 fork dependency disappears with them.

## 7. What this buys, and what it costs

**Buys:** one SDL version in the process — no symbol-collision class at all, so
the sealing work in `SDL3_REWRITE_PLAN.md` §4.1 becomes unnecessary. A modern
audio/input stack. Frontend and core share one event vocabulary.

**Costs, stated plainly:** DOSBox-X has carried dual SDL1/SDL2 paths since 2017
(upstream issue #431), there is **no upstream SDL3 effort to ride**, and this
branch is ours to maintain against every upstream merge. The scoping in §2 is
what keeps that cost bounded — if the port spreads outside the headless object
set, the maintenance burden grows with it.
