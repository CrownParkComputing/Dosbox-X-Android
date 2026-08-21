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

    test('notifies so the emulator view redraws on a toolbar tap', () {
      var notifications = 0;
      final ui = EmulatorUiState()..addListener(() => notifications++);
      ui.togglePad();
      expect(notifications, 1);
      ui.applyPadDefault(true);
      expect(notifications, 1, reason: 'no change, no rebuild');
    });
  });
}
