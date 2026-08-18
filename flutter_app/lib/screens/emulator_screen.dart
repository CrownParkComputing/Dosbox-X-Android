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
import 'package:flutter/services.dart';

import '../ffi/dosbox_core.dart';
import '../services/app_prefs.dart';
import '../theme/dosbox_theme.dart';
import '../widgets/assignable_action_button.dart';
import '../widgets/framebuffer_view.dart';
import '../widgets/on_screen_keyboard.dart';
import '../widgets/wobble_joystick.dart';

class EmulatorScreen extends StatefulWidget {
  final DosboxCore core;

  /// Title of the running session, for the status overlay.
  final String title;

  /// Whether an external gamepad is connected, which decides whether the
  /// on-screen pad is drawn in `auto` mode.
  final bool controllerConnected;

  final VoidCallback? onExit;

  const EmulatorScreen({
    super.key,
    required this.core,
    required this.title,
    this.controllerConnected = false,
    this.onExit,
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

  bool _showKeyboard = false;
  bool _mouseMode = false;
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
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  // --- Input plumbing ------------------------------------------------------

  void _pushJoystick() {
    widget.core.joystick(0, _joyMask, axisX: _joyAxisX, axisY: _joyAxisY);
  }

  void _onStick(int mask, double axisX, double axisY) {
    // Preserve button bits already held while replacing the direction bits, so
    // holding fire and then moving does not cancel the fire.
    const directions =
        DosJoyBits.up | DosJoyBits.down | DosJoyBits.left | DosJoyBits.right;
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
        widget.core.keyEvent(scancode, pressed);
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
    widget.core.keyEvent(scancode, event is KeyDownEvent);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final showPad =
        _joystickEnabled &&
        _padMode.visibleWith(controllerConnected: widget.controllerConnected);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(child: _picture()),
            if (_showStatus) _statusOverlay(),
            _toolbar(),
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
          widget.core.mouseMotion(d.delta.dx.round(), d.delta.dy.round()),
      onTapDown: (_) => widget.core.mouseButton(0, true),
      onTapUp: (_) => widget.core.mouseButton(0, false),
      onLongPressStart: (_) => widget.core.mouseButton(1, true),
      onLongPressEnd: (_) => widget.core.mouseButton(1, false),
      child: view,
    );
  }

  Widget _statusOverlay() {
    final frame = widget.core.frameCounter;
    final program = widget.core.runningProgram;
    final status = widget.core.statusLine;
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
          '${widget.title}\n$detail',
          style: DosTextStyles.statusLine,
        ),
      ),
    );
  }

  Widget _toolbar() {
    return Positioned(
      right: 8,
      top: 8,
      child: Column(
        children: [
          _ToolButton(
            icon: Icons.keyboard,
            active: _showKeyboard,
            tooltip: 'On-screen keys',
            onTap: () => setState(() => _showKeyboard = !_showKeyboard),
          ),
          _ToolButton(
            icon: Icons.mouse,
            active: _mouseMode,
            tooltip: 'Trackpad mouse',
            onTap: () => setState(() => _mouseMode = !_mouseMode),
          ),
          _ToolButton(
            icon: widget.core.isPaused ? Icons.play_arrow : Icons.pause,
            active: widget.core.isPaused,
            tooltip: widget.core.isPaused ? 'Resume' : 'Pause',
            onTap: () =>
                setState(() => widget.core.setPaused(!widget.core.isPaused)),
          ),
          if (widget.onExit != null)
            _ToolButton(
              icon: Icons.close,
              active: false,
              tooltip: 'Close game',
              onTap: widget.onExit!,
            ),
        ],
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
              ? JoyButtonBinding(DosJoyBits.button1)
              : KeyActionBinding(_buttonAScancode!),
          onAction: _onAction,
        ),
        const SizedBox(height: 10),
        ActionButton(
          binding: _buttonBScancode == null
              ? JoyButtonBinding(DosJoyBits.button2)
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
        onKey: widget.core.keyEvent,
        extraKeys: _customButtons,
      ),
    );
  }
}

/// One of the small overlay buttons down the right-hand side of the picture
/// (keyboard, mouse mode, pause, exit).
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: active
                  ? DosColors.selectedFill
                  : Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: active ? DosColors.accentAmber : DosColors.panelStroke,
              ),
            ),
            child: Icon(
              icon,
              size: 19,
              color: active ? DosColors.accentAmber : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}
