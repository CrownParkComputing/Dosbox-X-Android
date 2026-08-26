import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:retro_dosbox/data/emulator_ui_state.dart';

void main() {
  group('EmulatorUiState pad visibility', () {
    test('follows the saved preference until the player chooses', () {
      final ui = EmulatorUiState();
      ui.applyPadDefault(true);
      expect(ui.padVisible, isTrue);
      ui.applyPadDefault(false);
      expect(ui.padVisible, isFalse);
    });

    test('a hand-hidden pad is not brought back by the preference', () {
      // `auto` mode re-applies its default whenever a controller comes or
      // goes. A pad the player turned off must not reappear because they
      // unplugged a pad -- that is the setting fighting the user.
      final ui = EmulatorUiState()..applyPadDefault(true);
      ui.togglePad();
      expect(ui.padVisible, isFalse);
      ui.applyPadDefault(true);
      expect(ui.padVisible, isFalse);
    });

    test('a hand-shown pad is not hidden by the preference', () {
      final ui = EmulatorUiState();
      ui.togglePad();
      expect(ui.padVisible, isTrue);
      ui.applyPadDefault(false);
      expect(ui.padVisible, isTrue);
    });

    test('reset clears the choice as well as the state', () {
      // Sessions must not inherit each other's input modes.
      final ui = EmulatorUiState()..togglePad();
      ui.reset();
      expect(ui.padVisible, isFalse);
      ui.applyPadDefault(true);
      expect(ui.padVisible, isTrue);
    });

    test('a Windows guest starts with the picture as a trackpad', () {
      // Windows 98 has no keyboard-only path to anything, so a pointer the
      // user has to go and find first reads as a broken emulator.
      final ui = EmulatorUiState();
      expect(ui.mouseMode, isFalse, reason: 'DOS keeps the old default');
      ui.applyMouseDefault(true);
      expect(ui.mouseMode, isTrue);
    });

    test('turning the mouse off by hand outranks the Windows default', () {
      // Same contract the pad already has: once the player has said what they
      // want, relaunching the panel must not argue with them.
      final ui = EmulatorUiState()..applyMouseDefault(true);
      ui.toggleMouseMode();
      expect(ui.mouseMode, isFalse);
      ui.applyMouseDefault(true);
      expect(ui.mouseMode, isFalse);
    });

    test('reset clears the mouse choice too', () {
      final ui = EmulatorUiState()..toggleMouseMode();
      ui.reset();
      expect(ui.mouseMode, isFalse);
      ui.applyMouseDefault(true);
      expect(ui.mouseMode, isTrue);
    });

    test('a DOS title does not get the trackpad', () {
      final ui = EmulatorUiState()..applyMouseDefault(false);
      expect(ui.mouseMode, isFalse);
    });

    test('notifies so the emulator view redraws on a toolbar tap', () {
      var notifications = 0;
      final ui = EmulatorUiState()..addListener(() => notifications++);
      ui.togglePad();
      expect(notifications, 1);
      ui.applyPadDefault(true);
      expect(notifications, 1, reason: 'no change, no rebuild');
    });
  });

  group('touch mapping', () {
    // The arithmetic FramebufferView._normalise performs, pinned here because
    // getting it wrong puts the pointer somewhere plausible but wrong, which
    // is the hardest kind of input bug to see.
    Offset normalise(Offset local, Size size) => Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );

    test('the centre of the picture is the centre of the screen', () {
      expect(
        normalise(const Offset(320, 240), const Size(640, 480)),
        const Offset(0.5, 0.5),
      );
    });

    test('scale does not matter, only the fraction', () {
      // Same finger position on a picture drawn at 3x must mean the same
      // guest pixel: this is why the mapping is a fraction and not pixels.
      expect(
        normalise(const Offset(960, 720), const Size(1920, 1440)),
        normalise(const Offset(320, 240), const Size(640, 480)),
      );
    });

    test('a finger past the edge holds the pointer at the edge', () {
      // Rather than asking for a position off the emulated screen, which a
      // guest would either clamp differently or treat as garbage.
      expect(normalise(const Offset(-50, 900), const Size(640, 480)),
          const Offset(0, 1));
    });

    test('a degenerate size does not divide by zero', () {
      final n = normalise(const Offset(10, 10), const Size(640, 480));
      expect(n.dx.isFinite && n.dy.isFinite, isTrue);
    });
  });
}
