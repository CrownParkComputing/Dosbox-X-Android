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
import '../data/touch_pointer_gestures.dart';
import 'package:flutter/services.dart';

import '../ffi/retrodosbox_core.dart';
import '../services/app_prefs.dart';
import '../services/emulator_input.dart';
import '../theme/retrodosbox_theme.dart';
import '../widgets/movable_control.dart';
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

  /// The picture is a pointer surface for this session whatever the toolbar
  /// says. Set for a bootable disk image, where a guest OS's own pointer is
  /// the only interface there is.
  final bool absolutePointer;

  const EmulatorScreen({
    super.key,
    required this.core,
    required this.input,
    required this.title,
    this.controllerConnected = false,
    this.onExit,
    this.onPause,
    required this.ui,
    this.absolutePointer = false,
  });

  @override
  State<EmulatorScreen> createState() => _EmulatorScreenState();
}

class _EmulatorScreenState extends State<EmulatorScreen> {
  final FocusNode _focusNode = FocusNode();

  bool _joystickEnabled = false;
  bool _leftHanded = false;

  /// Centre of each on-screen control as fractions of the play area --
  /// the family's layout contract (see AppPrefs.getControlPositions).
  Map<String, Offset> _controlPositions = const {};
  OnScreenPadMode _padMode = OnScreenPadMode.auto;
  List<int> _customButtons = const <int>[];
  int? _buttonAScancode;
  int? _buttonBScancode;

  // Owned by the workbench, because the buttons that toggle them are on its
  // status row rather than in here. See EmulatorUiState.
  bool get _showKeyboard => widget.ui.keyboardVisible;
  bool get _mouseMode => widget.ui.mouseMode;

  /// Whether the picture should act as a pointer surface regardless of the
  /// toolbar toggle.
  ///
  /// A booted guest OS has no other way in. Making touch conditional on a
  /// button the user has to find first means a Windows desktop that ignores
  /// every tap, which is indistinguishable from a broken emulator -- and if
  /// anything upstream fails to set that toggle, the machine is simply
  /// unusable. DOS titles keep the toggle, because there the picture may need
  /// to be a joystick instead.
  bool get _touchIsPointer => _mouseMode || widget.absolutePointer;
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
    AppPrefs.getControlPositions().then((stored) {
      if (mounted && stored.isNotEmpty) {
        setState(() => _controlPositions = stored);
      }
    });
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
    _holdTimer?.cancel();
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
        child: LayoutBuilder(builder: (context, constraints) {
          final area = constraints.biggest;
          return Stack(
            children: [
              Positioned.fill(child: _picture()),
              if (_showStatus) _statusOverlay(),
              if (showPad) ..._padControls(area),
              if (_showKeyboard) _keyboard(),
            ],
          );
        }),
      ),
    );
  }

  Widget _picture() {
    // The touchscreen IS the mouse: the pointer goes where the finger is,
    // rather than the finger nudging it from wherever it happened to be.
    //
    // This used to be a trackpad -- a GestureDetector whose onPanUpdate fed
    // relative deltas. That is the right model for a laptop and the wrong one
    // for a handheld: on a Windows desktop you look at the thing you want and
    // touch it, and a relative pointer means hunting a cursor that starts
    // somewhere else entirely. It also went through Flutter's gesture arena,
    // which swallowed the first movement of every touch to the drag threshold
    // and cancelled a tap the moment it became a drag -- leaving the left
    // button held down for the rest of the session.
    //
    // Placement is FramebufferView's job because only it knows where the
    // picture is; this only has to say what a touch means.
    final view = Center(
      child: FramebufferView(
        core: widget.core,
        onTouchDown: _touchIsPointer ? _onTouchDown : null,
        onTouchMove: _touchIsPointer ? _onTouchMove : null,
        onTouchUp: _touchIsPointer ? _onTouchUp : null,
      ),
    );
    return view;
  }

  /// Touch means one of three things; TouchPointerGestures decides which.
  ///
  /// Movement is RELATIVE -- the pointer follows the finger rather than
  /// jumping to it -- and a tap is a click on the way UP. See
  /// TouchPointerGestures for why both of those are the way they are.
  final _gestures = TouchPointerGestures();

  /// Movement units per emulated pixel.
  ///
  /// DOSBox-X builds a PS/2 packet as (accumulated * (1 << resolution)) / 16.
  /// Windows programs resolution 3, so 16/8 = 2 units make one pixel. Sending
  /// the pixel count raw made the pointer eight times too fast.
  static const int _unitsPerPixel = 2;

  void _apply(TouchAction action, Offset deltaEmulatedPixels) {
    // The hold timer only runs while a right click is still possible: one
    // still finger, nothing held, nothing fired.
    if (!_gestures.holdArmed) _holdTimer?.cancel();
    switch (action) {
      case TouchAction.none:
        break;
      case TouchAction.leftClick:
        _click(0);
      case TouchAction.rightClick:
        _click(1);
      case TouchAction.leftDown:
        widget.input.mouseButton(0, true);
      case TouchAction.leftUp:
        widget.input.mouseButton(0, false);
      case TouchAction.move:
        final dx = (deltaEmulatedPixels.dx * _unitsPerPixel).round();
        final dy = (deltaEmulatedPixels.dy * _unitsPerPixel).round();
        // Sub-pixel travel rounds to nothing, and a packet saying "no
        // movement" is just noise on a wire the guest drains slowly.
        if (dx == 0 && dy == 0) return;
        widget.input.mouseMotion(dx, dy);
    }
  }

  /// Arms the hold-still right click; TouchPointerGestures decides on
  /// expiry whether it still applies. The timer lives here because the
  /// grammar class is deliberately synchronous, so it can be tested.
  Timer? _holdTimer;

  void _onTouchDown(Offset n, int pointers) {
    _apply(_gestures.onDown(pointers), Offset.zero);
    if (pointers == 1) {
      _holdTimer?.cancel();
      _holdTimer = Timer(TouchPointerGestures.holdDuration, () {
        if (mounted) _apply(_gestures.onHoldExpired(), Offset.zero);
      });
    }
  }

  void _onTouchMove(Offset deltaEmulatedPixels) =>
      _apply(_gestures.onMove(deltaEmulatedPixels), deltaEmulatedPixels);

  void _onTouchUp(int pointers) {
    _holdTimer?.cancel();
    _apply(_gestures.onUp(pointers), Offset.zero);
  }

  /// Press and release together, where the pointer already is.
  void _click(int button) {
    widget.input.mouseButton(button, true);
    widget.input.mouseButton(button, false);
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

  /// The stick and the button pair, each movable in layout mode and
  /// remembered -- the same fraction-of-play-area contract as Retro-C64,
  /// Retro-Spectrum and Retro-Saturn. Left-handed mode only chooses the
  /// DEFAULT sides; a dragged position always wins.
  List<Widget> _padControls(Size area) {
    final stickDefault =
        _leftHanded ? const Offset(0.88, 0.78) : const Offset(0.12, 0.78);
    final buttonsDefault =
        _leftHanded ? const Offset(0.12, 0.78) : const Offset(0.88, 0.78);
    final editing = widget.ui.editingLayout;

    Widget movable(String id, Offset fallback, String label, Widget child) {
      return MovableControl(
        area: area,
        fraction: _controlPositions[id] ?? fallback,
        editing: editing,
        label: label,
        onMoved: (f) =>
            setState(() => _controlPositions = {..._controlPositions, id: f}),
        onMoveEnd: () {
          final f = _controlPositions[id];
          if (f != null) AppPrefs.setControlPosition(id, f);
        },
        child: child,
      );
    }

    return [
      movable(
        'stick',
        stickDefault,
        'Stick',
        WobbleJoystick(onJoystick: _onStick),
      ),
      movable(
        'buttons',
        buttonsDefault,
        'Buttons',
        Column(
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
        ),
      ),
    ];
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
