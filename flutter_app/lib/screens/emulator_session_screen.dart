import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/save_state_service.dart';
import '../services/app_log.dart';
import '../services/video_settings.dart';
import '../data/emulator_ui_state.dart';
import '../data/game_entry.dart';
import '../services/emulator_input.dart';
import '../ffi/retrodosbox_core.dart';
import '../theme/retrodosbox_theme.dart';
import 'emulator_screen.dart';

/// How a session ended, from the workbench's point of view.
///
/// [paused] keeps the engine warm behind the workbench (snapshotted on
/// desktop, process-paused on Android) so the Running tab offers it back.
/// [closed] is the clean kill with no resume path.
enum SessionExit { paused, closed }

/// The emulator's own screen -- the family pattern shared with Retro-Amiga,
/// Retro-Saturn and Retro-C64. Launching pushes this route fullscreen;
/// everything a player needs mid-game lives here, and both ways out land
/// back on the workbench in exactly one place.
///
/// A corner handle opens the pause menu (engine paused, picture dimmed):
/// Resume, Save and exit, Close. The right-hand rail carries the in-game
/// tools that used to sit on the workbench status bar -- pad, keys, trackpad
/// mouse and the two click buttons -- as labelled buttons.
class EmulatorSessionScreen extends StatefulWidget {
  final RetroDosboxCore core;
  final EmulatorInput input;
  final EmulatorUiState ui;
  final GameEntry entry;
  final bool controllerConnected;

  /// Pauses or resumes the engine itself, on whichever side of the process
  /// boundary it lives. Owned by the workbench, which knows the platform.
  final Future<void> Function(bool paused) setEnginePaused;

  /// The engine-side half of Save and exit: snapshot (desktop) or leave the
  /// process paused (Android). Navigation is this screen's job, not the
  /// callback's.
  final Future<void> Function() onSaveAndExit;

  /// The engine-side half of Close: persist archive saves and stop the
  /// engine.
  final Future<void> Function() onClose;

  /// Load this per-title state slot once the machine is up -- the States
  /// tab's resume path. Null for an ordinary launch.
  final int? resumeSlot;

  const EmulatorSessionScreen({
    super.key,
    required this.core,
    required this.input,
    required this.ui,
    required this.entry,
    required this.controllerConnected,
    required this.setEnginePaused,
    required this.onSaveAndExit,
    required this.onClose,
    this.resumeSlot,
  });

  @override
  State<EmulatorSessionScreen> createState() => _EmulatorSessionScreenState();
}

class _EmulatorSessionScreenState extends State<EmulatorSessionScreen> {
  /// The pause menu: engine stopped, picture dimmed, choices pinned up.
  bool _menuOpen = false;

  /// Whether the corner handle and rail are on screen. They hide a few
  /// seconds after the last touch: a 4:3 machine on a widescreen handheld
  /// has no width to lend to furniture that is only occasionally wanted.
  bool _controlsVisible = true;
  Timer? _controlsTimer;

  /// Guards the two exits against double taps -- the second press of Close
  /// while the first is still persisting saves must not run the teardown
  /// twice.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // The session owns the whole screen: hide the system bars for the
    // duration and give them back on the way out. Sticky, because an edge
    // swipe on a handheld is easy to do by accident mid-game.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final int? slot = widget.resumeSlot;
    if (slot != null) _loadStateWhenReady(slot);
    _restartControlsTimer();
  }

  /// Waits for the engine to actually be emulating (the frame counter
  /// moving) before asking it to load the slot -- a load fired during boot
  /// lands before the state machinery exists and is silently dropped.
  void _loadStateWhenReady(int slot) {
    final int startCounter = widget.core.frameCounter;
    var polls = 0;
    Timer.periodic(const Duration(milliseconds: 250), (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      polls++;
      if (widget.core.frameCounter > startCounter + 8) {
        t.cancel();
        widget.input.loadState(slot);
        AppLog.log('resume: loadState($slot) sent');
      } else if (polls > 120) {
        t.cancel();
        AppLog.log('resume: engine never started producing frames');
      }
    });
  }

  /// Saves the running game into its next rotating slot, with a thumbnail
  /// from the live framebuffer, and says so.
  Future<void> _saveNamedState() async {
    final entry = widget.entry;
    final int slot = await SaveStateService.nextSlotFor(entry.slug);
    widget.input.saveState(slot);
    await SaveStateService.record(
      slug: entry.slug,
      title: entry.title,
      gamePath: entry.path,
      slot: slot,
      frame: widget.core.getFramebuffer(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved — slot $slot. The States tab lists it.')),
    );
  }

  /// The rail's Disk tool: put another disc of this game in the drive.
  /// The machine keeps running -- DOSBox-X raises a real "medium changed"
  /// to the guest, exactly like swapping a CD.
  Future<void> _swapDisc() async {
    final String? chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: RetroDosboxColors.cardFill,
      builder: (BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Swap disc')),
              const Divider(height: 1),
              for (final d in widget.entry.discs)
                ListTile(
                  leading: Icon(d == _currentDisc
                      ? Icons.album
                      : Icons.album_outlined),
                  title: Text(p.basename(d),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, d),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    widget.input.cdInsert(chosen);
    setState(() => _currentDisc = chosen);
  }

  /// The disc currently in the drive, for the chooser's tick. Starts as
  /// the first of the set (which is what launch mounts).
  late String? _currentDisc =
      widget.entry.discs.isNotEmpty ? widget.entry.discs.first : null;

  @override
  void dispose() {
    _controlsTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _restartControlsTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && !_menuOpen) setState(() => _controlsVisible = false);
    });
  }

  void _wakeControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _restartControlsTimer();
  }

  void _setMenu(bool open) {
    setState(() {
      _menuOpen = open;
      _controlsVisible = true;
    });
    // The menu freezes the machine for real -- audio included -- rather
    // than dimming a game that plays on underneath.
    unawaited(widget.setEnginePaused(open));
    if (!open) _restartControlsTimer();
  }

  Future<void> _saveAndExit() async {
    if (_leaving) return;
    _leaving = true;
    await widget.onSaveAndExit();
    if (!mounted) return;
    Navigator.of(context).pop(SessionExit.paused);
  }

  Future<void> _close() async {
    if (_leaving) return;
    _leaving = true;
    await widget.onClose();
    if (!mounted) return;
    Navigator.of(context).pop(SessionExit.closed);
  }

  /// Press and release a mouse button where the pointer already is. The
  /// release is queued immediately after the press: a button left held is
  /// the selection-box bug the click/point separation exists to kill.
  void _clickMouse(int button) {
    widget.input.mouseButton(button, true);
    widget.input.mouseButton(button, false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // The machine. EmulatorScreen still draws the framebuffer, the
            // on-screen pad and keys, and speaks input; the session chrome
            // lives out here on top of it.
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _wakeControls(),
                child: EmulatorScreen(
                  ui: widget.ui,
                  // A booted guest OS is driven by its own pointer and
                  // nothing else, so the picture is a touch pointer for the
                  // whole session rather than waiting for the rail's mouse
                  // button.
                  absolutePointer: widget.entry.kind == GameKind.bootImage,
                  core: widget.core,
                  input: widget.input,
                  title: widget.entry.title,
                  controllerConnected: widget.controllerConnected,
                ),
              ),
            ),
            if (_menuOpen) ...[
              // Dim the frozen picture. Tapping the picture resumes --
              // the cheapest way back into the game is the game itself.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setMenu(false),
                  child: Container(color: const Color(0xB3000000)),
                ),
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ResumeButton(onTap: () => _setMenu(false)),
                    const SizedBox(height: 28),
                    _MenuChoice(
                      icon: Icons.bookmark_add_outlined,
                      label: 'Save and exit',
                      detail:
                          'Keep your place and return to the workbench',
                      onTap: () => unawaited(_saveAndExit()),
                    ),
                    const SizedBox(height: 12),
                    _MenuChoice(
                      icon: Icons.close,
                      label: 'Close',
                      detail: 'End the session and return to the workbench',
                      onTap: () => unawaited(_close()),
                    ),
                  ],
                ),
              ),
            ],
            // The in-game tool rail, down the right edge where the thumb
            // already is. Hidden while the menu is up -- the menu IS the
            // controls then.
            if (!_menuOpen)
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Center(child: _toolRail()),
                  ),
                ),
              ),
            // The corner handle: the one control that is always reachable.
            // ☰ opens the pause menu; while the menu is up it reads ▶ and
            // resumes, so the same corner always undoes itself.
            Positioned(
              left: 4,
              top: 4,
              child: AnimatedOpacity(
                opacity: (_controlsVisible || _menuOpen) ? 1 : 0.25,
                duration: const Duration(milliseconds: 200),
                child: Material(
                  color: const Color(0x66000000),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      _wakeControls();
                      _setMenu(!_menuOpen);
                    },
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        _menuOpen ? Icons.play_arrow : Icons.menu,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolRail() {
    final ui = widget.ui;
    return ListenableBuilder(
      listenable: ui,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Screen shape without leaving the game -- cycles the same four
          // modes as the Video tab (VideoSettings is a global listenable,
          // so the picture follows instantly).
          _RailTool(
            icon: switch (VideoSettings.instance.aspect) {
              AspectMode.stretch => Icons.fit_screen,
              AspectMode.integer => Icons.grid_on,
              AspectMode.square => Icons.crop_square,
              AspectMode.authentic => Icons.aspect_ratio,
            },
            label: 'Shape',
            tooltip:
                '${VideoSettings.instance.aspect.label} — tap for the next '
                'mode',
            onTap: () {
              _wakeControls();
              final modes = AspectMode.values;
              final next = modes[(VideoSettings.instance.aspect.index + 1) %
                  modes.length];
              VideoSettings.instance.setAspect(next);
              setState(() {});
            },
          ),
          if (widget.entry.discs.length > 1)
            _RailTool(
              icon: Icons.album,
              label: 'Disk',
              tooltip: 'Swap to another disc of this game',
              onTap: () {
                _wakeControls();
                unawaited(_swapDisc());
              },
            ),
          _RailTool(
            icon: Icons.save_outlined,
            label: 'Save',
            tooltip: 'Save your place into a named slot (States tab)',
            onTap: () {
              _wakeControls();
              unawaited(_saveNamedState());
            },
          ),
          _RailTool(
            icon: Icons.videogame_asset,
            label: 'Pad',
            lit: ui.padVisible,
            tooltip: 'On-screen joypad',
            onTap: () {
              _wakeControls();
              ui.togglePad();
            },
          ),
          _RailTool(
            icon: Icons.keyboard,
            label: 'Keys',
            lit: ui.keyboardVisible,
            tooltip: 'On-screen keys',
            onTap: () {
              _wakeControls();
              ui.toggleKeyboard();
            },
          ),
          // Only while the pad is up: moving controls that are not on
          // screen is a mode with nothing in it. Same tool, same glyph, as
          // the rest of the family.
          if (ui.padVisible)
            _RailTool(
              icon: ui.editingLayout ? Icons.check : Icons.open_with,
              label: 'Layout',
              lit: ui.editingLayout,
              tooltip: ui.editingLayout
                  ? 'Finish moving controls'
                  : 'Move the on-screen controls',
              onTap: () {
                _wakeControls();
                ui.toggleLayoutEditing();
              },
            ),
          _RailTool(
            icon: Icons.mouse,
            label: 'Mouse',
            lit: ui.mouseMode,
            tooltip: 'Touch moves the pointer',
            onTap: () {
              _wakeControls();
              ui.toggleMouseMode();
            },
          ),
          // Clicking is separate from pointing, and that separation is the
          // whole point: touch used to both move the pointer AND press the
          // button, so every reposition dragged a selection box.
          _RailTool(
            icon: Icons.ads_click,
            label: 'LMB',
            tooltip: 'Left click where the pointer is',
            onTap: () {
              _wakeControls();
              _clickMouse(0);
            },
          ),
          _RailTool(
            icon: Icons.menu_open,
            label: 'RMB',
            tooltip: 'Right click where the pointer is',
            onTap: () {
              _wakeControls();
              _clickMouse(1);
            },
          ),
        ],
      ),
    );
  }
}

/// One labelled tool on the session rail: a 34px circle with its name under
/// it, matching the Amiga, Saturn and C64 rails.
class _RailTool extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool lit;
  final VoidCallback onTap;

  const _RailTool({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.lit = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: lit
                  ? RetroDosboxColors.accentAmber
                  : const Color(0x66000000),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Tooltip(
                message: tooltip,
                child: InkWell(
                  onTap: onTap,
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(
                      icon,
                      color: lit ? Colors.black : Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 9,
                shadows: [Shadow(blurRadius: 3, color: Colors.black)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The big centred resume control on the pause menu.
class _ResumeButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ResumeButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RetroDosboxColors.accentAmber,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: const SizedBox(
          width: 72,
          height: 72,
          child: Icon(Icons.play_arrow, color: Colors.black, size: 44),
        ),
      ),
    );
  }
}

/// A pause-menu row: icon, name, and a line saying what it will do.
class _MenuChoice extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  const _MenuChoice({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE0181C20),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 320,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
