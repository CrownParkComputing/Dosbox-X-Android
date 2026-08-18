// External gamepad/joystick support, feeding the emulated PC joystick.
//
// Flutter has no first-party controller API, so this uses the `gamepads`
// package (github.com/flame-engine/gamepads), which supports Linux desktop,
// Android, iOS, macOS, Windows and Web with a normalized button/axis model.
//
// The original of this code was written without a controller to test
// against, which is how the stick Y axis ended up inverted (see the axis
// handling below). Detection and button mapping have since been exercised on
// real hardware: an Xbox Wireless Controller on Linux and the Retroid Pocket
// Flip2's built-in pad on Android. Treat any remaining axis/button
// convention here as verified only for those two pads.
//
// Note what this does NOT do: many DOS games are keyboard-only and never
// read the game port at all. Turning pad input into key presses for those is
// a mapping concern that lives above this service -- all this produces is a
// [DosJoyBits] mask.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gamepads/gamepads.dart';

import '../ffi/dosbox_core.dart';

class GamepadService {
  StreamSubscription<NormalizedGamepadEvent>? _sub;
  Timer? _pollTimer;
  final _maskController = StreamController<int>.broadcast();
  int _mask = 0;
  double _stickX = 0, _stickY = 0;

  /// Whether Gamepads.list() currently reports any connected controller.
  /// Polled every couple of seconds because the package exposes no
  /// connect/disconnect stream -- used to auto-hide the on-screen virtual
  /// joystick/action buttons when a real controller is present.
  final ValueNotifier<bool> connected = ValueNotifier(false);

  /// Joystick mask contributed by the external gamepad (the same
  /// [DosJoyBits] shape as the virtual joystick/action buttons). The
  /// listener is responsible for OR-ing this with the other input sources
  /// before calling DosboxCore.joystick -- this service does not call the
  /// core directly so it can't stomp on the virtual controls' state.
  Stream<int> get maskChanges => _maskController.stream;

  void start() {
    _sub = Gamepads.normalizedEvents.listen(handleEvent, onError: (_) {
      // Best-effort: some platforms/sandboxes may not support gamepad
      // enumeration at all (no /dev/input access, no permission, etc).
      // Swallow rather than crash the emulator screen.
    });
    _pollConnection();
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _pollConnection());
  }

  Future<void> _pollConnection() async {
    try {
      final list = await Gamepads.list();
      final next = list.isNotEmpty;
      if (next != connected.value) {
        // Logged because this value silently decides whether the on-screen
        // joystick appears: in `auto` mode a controller the user does not have
        // makes the pad vanish with no way to tell why from the screen alone.
        debugPrint('dosbox: controllers=${list.length} '
            '[${list.map((g) => '${g.id}/${g.name}').join(', ')}]');
      }
      connected.value = next;
    } catch (_) {
      // See start()'s onError comment.
    }
  }

  void _setBit(int bit, bool on) {
    final next = on ? (_mask | bit) : (_mask & ~bit);
    if (next == _mask) return;
    _mask = next;
    _maskController.add(_mask);
  }

  /// Folds one normalized pad event into the joystick mask.
  ///
  /// Public (and directly exercised by test/services/gamepad_service_test.dart)
  /// because the axis convention here is the sort of thing that gets guessed
  /// wrong -- the stick Y axis WAS guessed wrong, and up/down came out
  /// swapped on every real pad until someone plugged one in.
  @visibleForTesting
  void handleEvent(NormalizedGamepadEvent event) {
    final button = event.button;
    if (button != null) {
      final down = event.value != 0;
      switch (button) {
        case GamepadButton.dpadUp:
          _setBit(DosJoyBits.up, down);
          break;
        case GamepadButton.dpadDown:
          _setBit(DosJoyBits.down, down);
          break;
        case GamepadButton.dpadLeft:
          _setBit(DosJoyBits.left, down);
          break;
        case GamepadButton.dpadRight:
          _setBit(DosJoyBits.right, down);
          break;
        // A/B/X/Y map straight onto the four game-port buttons, in the order
        // a two-stick PC gamepad reports them. A four-button PC joystick is
        // two two-button sticks as far as the hardware is concerned, so
        // buttons 3 and 4 are only read by games that expect that layout;
        // sending them costs nothing where they are ignored.
        case GamepadButton.a:
          _setBit(DosJoyBits.button1, down);
          break;
        case GamepadButton.b:
          _setBit(DosJoyBits.button2, down);
          break;
        case GamepadButton.x:
          _setBit(DosJoyBits.button3, down);
          break;
        case GamepadButton.y:
          _setBit(DosJoyBits.button4, down);
          break;
        default:
          break;
      }
      return;
    }

    final axis = event.axis;
    if (axis == GamepadAxis.leftStickX) {
      _stickX = event.value;
    } else if (axis == GamepadAxis.leftStickY) {
      _stickY = event.value;
    } else {
      return;
    }
    // A physical stick rests a little off centre and jitters there; without
    // a dead zone the emulated joystick would report a permanent slight lean
    // and games would drift.
    const deadZone = 0.35;
    _setBit(DosJoyBits.left, _stickX < -deadZone);
    _setBit(DosJoyBits.right, _stickX > deadZone);
    // Stick Y is Up = NEGATIVE, Down = POSITIVE -- the standard Android
    // MotionEvent.AXIS_Y / SDL convention, where the Y axis points DOWN the
    // screen. This was originally written the other way round (guessed as
    // "Up = +1" when this file was authored with no controller plugged in,
    // see the header note), which swapped up and down on a real pad.
    _setBit(DosJoyBits.up, _stickY < -deadZone);
    _setBit(DosJoyBits.down, _stickY > deadZone);
  }

  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    _maskController.close();
    connected.dispose();
  }
}
