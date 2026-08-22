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
// a mapping concern that lives above this service -- all this produces is
// a [JoystickState] (mask + axes), which the caller forwards to the core.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gamepads/gamepads.dart';

import '../ffi/retrodosbox_core.dart';

/// Combined digital mask + analog axes reported by an external pad.
class JoystickState {
  final int mask;
  final double axisX;
  final double axisY;
  const JoystickState({required this.mask, required this.axisX, required this.axisY});

  static const JoystickState centered = JoystickState(mask: 0, axisX: 0, axisY: 0);

  @override
  bool operator ==(Object other) =>
      other is JoystickState &&
      other.mask == mask &&
      other.axisX == axisX &&
      other.axisY == axisY;

  @override
  int get hashCode => Object.hash(mask, axisX, axisY);

  @override
  String toString() =>
    'JoystickState(mask=0x${mask.toRadixString(16)}, x=$axisX, y=$axisY)';
}

class GamepadService {
  StreamSubscription<NormalizedGamepadEvent>? _sub;
  Timer? _pollTimer;
  Timer? _refreshTimer;
  final _stateController = StreamController<JoystickState>.broadcast();
  JoystickState _state = JoystickState.centered;

  /// Whether Gamepads.list() currently reports any connected controller.
  /// Polled every couple of seconds because the package exposes no
  /// connect/disconnect stream -- used to auto-hide the on-screen virtual
  /// joystick/action buttons when a real controller is present.
  final ValueNotifier<bool> connected = ValueNotifier(false);

  /// Combined mask + axes contributed by the external gamepad. The listener
  /// forwards this straight to [RetroDosboxCore.joystick] -- both halves are
  /// needed: digital DOS games read the mask via the BIOS joystick
  /// interface, while analog-era titles read the X/Y axes. Setting only
  /// one half leaves one of the two DOS game genres blind to the pad,
  /// which is what made Uridium (an analog-axis title) require constant
  /// re-tapping before this service also forwarded the axes.
  Stream<JoystickState> get stateChanges => _stateController.stream;

  void start() {
    _sub = Gamepads.normalizedEvents.listen(handleEvent, onError: (_) {
      // Best-effort: some platforms/sandboxes may not support gamepad
      // enumeration at all (no /dev/input access, no permission, etc).
      // Swallow rather than crash the emulator screen.
    });
    _pollConnection();
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _pollConnection());
    // Re-broadcast the last joystick state on a tight interval so the
    // C-bridge mailbox always has a fresh entry while a direction is held.
    // Android gamepad buttons are reported as one ACTION_DOWN on press and
    // one ACTION_UP on release with no auto-repeat, so a held direction
    // produces no events for the duration of the hold -- but the bridge's
    // mailbox is processed by the mainloop exactly once per request. A
    // periodic refresh keeps DOSBox-X's internal joystick struct populated
    // every frame even with no new events from the OS, which is what
    // makes a held d-pad feel fluid rather than choppy.
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _refresh(),
    );
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

  /// Re-emit the current state on a fixed cadence so the bridge mailbox
  /// is never stale. The broadcast is "force" because we always want the
  /// core to receive the latest state, even if no event has fired since
  /// the last call -- otherwise the C side's per-frame mailbox drain can
  /// leave the joystick stale between held-direction events.
  void _refresh() {
    if (_stateController.isClosed) return;
    _stateController.add(_state);
  }

  /// Broadcast the current state if it changed. Callers pass the FINAL
  /// [JoystickState] they want -- no derivation happens here. The previous
  /// design OR'd the passed mask with bits derived from the axes, which
  /// meant the explicit bit could never be cleared by an axis update; the
  /// fixed shape is "caller owns the full mask".
  void _emit({int? mask, double? axisX, double? axisY}) {
    final next = JoystickState(
      mask: mask ?? _state.mask,
      axisX: axisX ?? _state.axisX,
      axisY: axisY ?? _state.axisY,
    );
    if (next == _state) return;
    _state = next;
    _stateController.add(next);
  }

  /// Direction bits: derived from analog axes, also explicitly set/cleared
  /// by dpad presses. Bit 0..3 of the mask.
  static const int directionBits =
      RetroDosboxJoyBits.up |
      RetroDosboxJoyBits.down |
      RetroDosboxJoyBits.left |
      RetroDosboxJoyBits.right;

  /// Fire bits: A/B/X/Y map straight onto button1..button4. Bits 4..7.
  /// Kept independent of [directionBits] so an analog-stick update cannot
  /// accidentally clear a held fire button.
  static const int fireBits =
      RetroDosboxJoyBits.button1 |
      RetroDosboxJoyBits.button2 |
      RetroDosboxJoyBits.button3 |
      RetroDosboxJoyBits.button4;

  /// Dead-zone hysteresis for analog direction bits.
  ///
  /// Engage when the axis crosses `_engage`; release only when it falls
  /// back past `_release`. The gap stops the mask from flickering when
  /// the axis value sits right at the threshold and hardware jitter makes
  /// it cross on every sample.
  static const double _engage = 0.40;
  static const double _release = 0.30;

  /// Recompute the direction bits of [currentMask] from the analog axis
  /// values, leaving the fire bits alone. The previous implementation
  /// tried to express "if set release-on-center else set-on-engage" with
  /// a one-line boolean expression that -- traced through Dart's
  /// `&&`-binds-tighter-than-`||` rules -- kept a held bit engaged even
  /// after the stick returned to centre. The if/else below is the same
  /// logic but unambiguously correct: a set bit releases only when the
  /// axis is back inside the release threshold; a clear bit engages only
  /// when the axis has crossed past the engage threshold.
  int _deriveMask(double x, double y, int currentMask) {
    var m = currentMask & ~directionBits;
    final left = (currentMask & RetroDosboxJoyBits.left) != 0;
    final right = (currentMask & RetroDosboxJoyBits.right) != 0;
    final up = (currentMask & RetroDosboxJoyBits.up) != 0;
    final down = (currentMask & RetroDosboxJoyBits.down) != 0;
    if (left) {
      if (x > -_release) m &= ~RetroDosboxJoyBits.left;
    } else {
      if (x < -_engage) m |= RetroDosboxJoyBits.left;
    }
    if (right) {
      if (x < _release) m &= ~RetroDosboxJoyBits.right;
    } else {
      if (x > _engage) m |= RetroDosboxJoyBits.right;
    }
    if (up) {
      if (y > -_release) m &= ~RetroDosboxJoyBits.up;
    } else {
      if (y < -_engage) m |= RetroDosboxJoyBits.up;
    }
    if (down) {
      if (y < _release) m &= ~RetroDosboxJoyBits.down;
    } else {
      if (y > _engage) m |= RetroDosboxJoyBits.down;
    }
    return m;
  }

  /// Set or clear [bit] in [currentMask], preserving everything else.
  int _withBit(int currentMask, int bit, bool on) =>
      on ? currentMask | bit : currentMask & ~bit;

  /// Folds one normalized pad event into the joystick state.
  ///
  /// Public (and directly exercised by tests) because the axis convention
  /// here is the sort of thing that gets guessed wrong -- the stick Y axis
  /// WAS guessed wrong, and up/down came out swapped on every real pad
  /// until someone plugged one in.
  @visibleForTesting
  void handleEvent(NormalizedGamepadEvent event) {
    final button = event.button;
    if (button != null) {
      final down = event.value != 0;
      // Dpad presses also set the analog axes to their extreme, so an
      // analog-axis DOS game (Uridium, most flight sims) gets continuous
      // movement while the pad is held, not just one frame of mask. The
      // caller (this method) owns the mask end-to-end -- it sets or clears
      // the dpad bit AND updates the axis in one shot, which is why the
      // old _emit which OR'd the passed bit with bits derived from axes
      // could never actually clear the bit on release.
      switch (button) {
        case GamepadButton.dpadUp:
          _emit(
            mask: _withBit(_state.mask, RetroDosboxJoyBits.up, down),
            axisY: down ? -1.0 : 0.0,
          );
          return;
        case GamepadButton.dpadDown:
          _emit(
            mask: _withBit(_state.mask, RetroDosboxJoyBits.down, down),
            axisY: down ? 1.0 : 0.0,
          );
          return;
        case GamepadButton.dpadLeft:
          _emit(
            mask: _withBit(_state.mask, RetroDosboxJoyBits.left, down),
            axisX: down ? -1.0 : 0.0,
          );
          return;
        case GamepadButton.dpadRight:
          _emit(
            mask: _withBit(_state.mask, RetroDosboxJoyBits.right, down),
            axisX: down ? 1.0 : 0.0,
          );
          return;
        // A/B/X/Y map straight onto the four game-port buttons, in the order
        // a two-stick PC gamepad reports them. A four-button PC joystick is
        // two two-button sticks as far as the hardware is concerned, so
        // buttons 3 and 4 are only read by games that expect that layout;
        // sending them costs nothing where they are ignored.
        case GamepadButton.a:
          _emit(mask: _withBit(_state.mask, RetroDosboxJoyBits.button1, down));
          return;
        case GamepadButton.b:
          _emit(mask: _withBit(_state.mask, RetroDosboxJoyBits.button2, down));
          return;
        case GamepadButton.x:
          _emit(mask: _withBit(_state.mask, RetroDosboxJoyBits.button3, down));
          return;
        case GamepadButton.y:
          _emit(mask: _withBit(_state.mask, RetroDosboxJoyBits.button4, down));
          return;
        default:
          return;
      }
    }

    final axis = event.axis;
    if (axis == GamepadAxis.leftStickX) {
      final newX = event.value;
      // Derive the direction bits from the new axis values; keep the fire
      // bits the caller already set. The mask ends up whatever the caller
      // had for buttons 1..4 plus the dead-zone-derived direction bits.
      final newMask = _deriveMask(newX, _state.axisY, _state.mask);
      _emit(mask: newMask, axisX: newX);
    } else if (axis == GamepadAxis.leftStickY) {
      final newY = event.value;
      final newMask = _deriveMask(_state.axisX, newY, _state.mask);
      _emit(mask: newMask, axisY: newY);
    } else {
      return;
    }
  }

  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    _refreshTimer?.cancel();
    _stateController.close();
    connected.dispose();
  }
}
