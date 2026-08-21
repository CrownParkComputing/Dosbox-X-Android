// The in-session screen: the DOS picture plus whatever input surfaces the
// user has enabled.
//
// The input story here is materially different from the VICE app's, and it is
// worth stating why. A C64 game takes a joystick and occasionally a key. A DOS
// game might want a keyboard only, a keyboard and a mouse (every adventure and
// strategy game), an emulated PC joystick, or the numeric keypad. There is no
// single control scheme that covers the library, so this screen composes
// several optional ones and lets the user decide per title.
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/emulator_ui_state.dart';
import 'package:flutter/services.dart';

import '../ffi/retrodosbox_core.dart';
import '../services/app_prefs.dart';
import '../services/emulator_input.dart';
import '../theme/retrodosbox_theme.dart';
import '../widgets/assignable_action_button.dart';
import '../widgets/framebuffer_view.dart';
import '../widgets/on_screen_keyboard.dart';
import '../widgets/wobble_joystick.dart';

class EmulatorScreen extends StatefulWidget {
  final RetroDosboxCore core;

  /// Title of the running session, for the status overlay.
  final String title;

  /// Whether an external gamepad is connected, which decides whether the
  /// on-screen pad is drawn in `auto` mode.
  final bool controllerConnected;

  /// Where input goes. Not [core]: on Android the live engine is in another
  /// process, and this screen's core object is an idle handle whose input
  /// calls reach nothing. See EmulatorInput.
  final EmulatorInput input;

  final VoidCallback? onExit;

  /// Snapshot the running state and return to the library. The owning shell
  /// owns the save slot, the pause flag, and the navigation; this button is
  /// just a trigger.
  final VoidCallback? onPause;

  /// Keyboard and trackpad-mouse state, owned by the workbench because the
  /// buttons that toggle them live on its status row.
  final EmulatorUiState ui;

  const EmulatorScreen({
    super.key,
    required this.core,
    required this.input,
    required this.title,
    this.controllerConnected = false,
    this.onExit,
    this.onPause,
    required this.ui,
  });

  @override
  State<EmulatorScreen> createState() => _EmulatorScreenState();
}

class _EmulatorScreenState extends State<EmulatorScreen> {
  final FocusNode _focusNode = FocusNode();

  bool _joystickEnabled = false;
  bool _leftHanded = false;
  OnScreenPadMode _padMode = OnScreenPadMode.auto;
  List<int> _customButtons = const <int>[];
  int? _buttonAScancode;
  int? _buttonBScancode;

  // Owned by the workbench, because the buttons that toggle them are on its
  // status row rather than in here. See EmulatorUiState.
  bool get _showKeyboard => widget.ui.keyboardVisible;
  bool get _mouseMode => widget.ui.mouseMode;
  final bool _showStatus = true;

  /// Accumulated joystick bits from every source (on-screen stick, action
  /// buttons). Kept as one mask because the core takes a single state per
  /// port, not per-source events -- so the sources have to be merged here.
  int _joyMask = 0;
  double _joyAxisX = 0;
  double _joyAxisY = 0;

  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    // The toolbar's keyboard, mouse, and pad buttons live on the workbench's
    // status row and change state this screen draws from, so it has to follow
    // that state. It used to arrive only via the half-second status timer
    // below, which made every toggle look like a laggy button.
    widget.ui.addListener(_onUiChanged);
    _loadPrefs();
    // Keep this lightweight telemetry visible. A blank frame can mean either
    // a slow game startup or a failed DOS command; showing the core's frame,
    // program, and status state makes that distinction obvious.
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadPrefs() async {
    final joystick = await AppPrefs.getJoystickEnabled();
    final leftHanded = await AppPrefs.getLeftHandedInput();
    final padMode = await AppPrefs.getOnScreenPadMode();
    final custom = await AppPrefs.getCustomButtons();
    final a = await AppPrefs.getActionButtonScancode('a');
    final b = await AppPrefs.getActionButtonScancode('b');
    if (!mounted) return;
    setState(() {
      _joystickEnabled = joystick;
      _leftHanded = leftHanded;
      _padMode = padMode;
      _customButtons = custom;
      _buttonAScancode = a;
      _buttonBScancode = b;
    });
    _applyPadDefault();
  }

  /// Hands the saved preference to the shared state, which ignores it once the
  /// player has used the toolbar button.
  void _applyPadDefault() {
    widget.ui.applyPadDefault(
      _padMode.visibleWith(controllerConnected: widget.controllerConnected),
    );
  }

  @override
  void didUpdateWidget(EmulatorScreen old) {
    super.didUpdateWidget(old);
    // `auto` means "pad unless a controller is connected", and a controller
    // can be plugged in mid-game.
    if (old.controllerConnected != widget.controllerConnected) {
      _applyPadDefault();
    }
  }

  void _onUiChanged() {
    if (!mounted) return;
    // Asking for the pad is asking for a joystick. Without this the toolbar
    // button would be inert for anyone who had never opened Input settings:
    // the pad only draws when PC joystick emulation is on, and a button that
    // does nothing reads as a broken button rather than a missing setting.
    if (widget.ui.padVisible && !_joystickEnabled) {
      _joystickEnabled = true;
      unawaited(AppPrefs.setJoystickEnabled(true));
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.ui.removeListener(_onUiChanged);
    _statusTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  // --- Input plumbing ------------------------------------------------------

  void _pushJoystick() {
    widget.input.joystick(0, _joyMask, axisX: _joyAxisX, axisY: _joyAxisY);
  }

  void _onStick(int mask, double axisX, double axisY) {
    // Preserve button bits already held while replacing the direction bits, so
    // holding fire and then moving does not cancel the fire.
    const directions =
        RetroDosboxJoyBits.up | RetroDosboxJoyBits.down | RetroDosboxJoyBits.left | RetroDosboxJoyBits.right;
    _joyMask = (_joyMask & ~directions) | (mask & directions);
    _joyAxisX = axisX;
    _joyAxisY = axisY;
    _pushJoystick();
  }

  void _onAction(ActionBinding binding, bool pressed) {
    switch (binding) {
      case JoyButtonBinding(bit: final bit):
        _joyMask = pressed ? (_joyMask | bit) : (_joyMask & ~bit);
        _pushJoystick();
      case KeyActionBinding(scancode: final scancode):
        widget.input.keyEvent(scancode, pressed);
    }
  }

  /// Physical keyboard passthrough.
  ///
  /// Uses the physical key rather than the logical one on purpose: DOS reads
  /// scancodes, so the position of the key is what matters, not what character
  /// the host keyboard layout says it produces. A user on an AZERTY keyboard
  /// pressing the key where QWERTY has W should get W in a DOS game whose WASD
  /// controls are positional.
  /// Flutter's physical key -> SDL scancode.
  ///
  /// A table is unnecessary: PhysicalKeyboardKey is a USB HID usage ID, and
  /// SDL scancodes ARE HID usage IDs (SDL_SCANCODE_A == 4 == HID usage 0x04).
  /// The page is the high 16 bits; page 0x07 is the keyboard page, and
  /// anything else (media keys, mouse) is not a key DOS can see.
  static int? _physicalToScancode(PhysicalKeyboardKey key) {
    const keyboardPage = 0x00070000;
    if ((key.usbHidUsage & 0xFFFF0000) != keyboardPage) return null;
    final scancode = key.usbHidUsage & 0xFFFF;
    // Above the standard keyboard page there is nothing DOSBox-X maps.
    return (scancode > 0 && scancode < 0x100) ? scancode : null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final scancode = _physicalToScancode(event.physicalKey);
    if (scancode == null) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    widget.input.keyEvent(scancode, event is KeyDownEvent);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // The live answer, not the preference: the toolbar's pad button can
    // override it for this session, and the state it toggles lives on the
    // workbench because the button does. See EmulatorUiState.padVisible.
    final showPad = _joystickEnabled && widget.ui.padVisible;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        color: Colors.black,
        // No strip here. The tool buttons live on the workbench's status row,
        // below the panel, alongside the rail toggle and the loaded title -
        // the same place the Amiga and C64 front ends put theirs.
        //
        // Sharing that row rather than taking a band of its own is the point:
        // the row is already on screen, and a second band comes straight out
        // of the picture's height, which a 4:3 machine on a wide handheld has
        // none of to spare. Drawn ON the picture they covered the corner where
        // DOS titles put their own UI.
        //
        // The pad and keyboard stay here: those belong over the picture,
        // because they are how you play it.
        child: Stack(
          children: [
            Positioned.fill(child: _picture()),
            if (_showStatus) _statusOverlay(),
            if (showPad) _pad(),
            if (_showKeyboard) _keyboard(),
          ],
        ),
      ),
    );
  }

  Widget _picture() {
    final view = Center(child: FramebufferView(core: widget.core));
    if (!_mouseMode) return view;
    // Mouse mode turns the whole picture into a trackpad. Relative deltas
    // rather than absolute positioning, because DOS mouse drivers track
    // movement, and absolute jumps make cursors in games fly to a corner.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) =>
          widget.input.mouseMotion(d.delta.dx.round(), d.delta.dy.round()),
      onTapDown: (_) => widget.input.mouseButton(0, true),
      onTapUp: (_) => widget.input.mouseButton(0, false),
      onLongPressStart: (_) => widget.input.mouseButton(1, true),
      onLongPressEnd: (_) => widget.input.mouseButton(1, false),
      child: view,
    );
  }

  Widget _statusOverlay() {
    final frame = widget.core.frameCounter;
    final program = widget.core.runningProgram;
    final status = widget.core.statusLine;
    // The title itself is deliberately NOT shown here: it lives in the
    // workbench's bottom status bar now, outside the game picture, so this
    // overlay only carries transient state (booting, program, pause).
    final detail = frame == 0
        ? 'Starting DOSBox...'
        : (program ?? status ?? 'Running (frame $frame)');
    return Positioned(
      left: 10,
      top: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          detail,
          style: RetroDosboxTextStyles.statusLine,
        ),
      ),
    );
  }

  Widget _pad() {
    final stick = WobbleJoystick(onJoystick: _onStick);
    final buttons = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ActionButton(
          binding: _buttonAScancode == null
              ? JoyButtonBinding(RetroDosboxJoyBits.button1)
              : KeyActionBinding(_buttonAScancode!),
          onAction: _onAction,
        ),
        const SizedBox(height: 10),
        ActionButton(
          binding: _buttonBScancode == null
              ? JoyButtonBinding(RetroDosboxJoyBits.button2)
              : KeyActionBinding(_buttonBScancode!),
          onAction: _onAction,
        ),
      ],
    );

    // Left-handed mode swaps the stick and the buttons rather than mirroring
    // the whole layout, which is what left-handed players actually want.
    final children = _leftHanded ? [buttons, stick] : [stick, buttons];
    return Positioned(
      left: 16,
      right: 16,
      bottom: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: children,
      ),
    );
  }

  /// The full on-screen keyboard.
  ///
  /// Replaces the five-key strip this screen used to draw. That was enough for
  /// a game controlled by Esc/Enter/Space and nothing else -- it could not
  /// type a name into a high-score table, reach an F-key menu, or open a
  /// console. DOS software assumes a real keyboard, so on a tablet one has to
  /// be drawn rather than approximated.
  Widget _keyboard() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: OnScreenKeyboard(
        onKey: widget.input.keyEvent,
        extraKeys: _customButtons,
      ),
    );
  }
}

/// One of the small overlay buttons down the right-hand side of the picture
/// (keyboard, mouse mode, pause, exit).
