import 'package:flutter_test/flutter_test.dart';

import 'package:dosboxx_launcher/data/conf_generator.dart';
import 'package:dosboxx_launcher/data/dos_settings.dart';

void main() {
  test('a 486 conf carries its cycles, memory and mount', () {
    final String conf = ConfGenerator.generate(const DosSettings(
      machine: DosMachine.dx486,
      mountPath: '/storage/games/keen',
      autoexec: 'keen4e.exe',
    ));
    expect(conf, contains('cycles=26800'));
    expect(conf, contains('memsize=8'));
    expect(conf, contains('mount c "/storage/games/keen"'));
    expect(conf, contains('keen4e.exe'));
    expect(conf, contains('core=normal'));
  });

  test('no sound blaster means sbtype none, not absence', () {
    final String conf =
        ConfGenerator.generate(const DosSettings(soundBlaster: false));
    expect(conf, contains('sbtype=none'));
  });

    test('geek mode asks for the DOSBox-X menu bar, beginner mode does not', () {
      const DosSettings s = DosSettings(
        machine: DosMachine.dx486,
        mountPath: '/games/x',
        autoexec: 'X.EXE',
      );
      final String beginner = ConfGenerator.generate(s);
      expect(beginner, contains('showmenu=false'));
      expect(beginner, contains('showdetails=false'));

      final String geek = ConfGenerator.generate(s, null, true);
      expect(geek, contains('showmenu=true'));
      expect(geek, contains('showdetails=true'));
      // The menu must never cost us the fixes underneath it.
      expect(geek, contains('fullscreen=false'));
      expect(geek, contains('output=surface'));
      // Autolock would capture the mouse on the first tap and the core would
      // then never route a click to the menu bar.
      expect(geek, contains('autolock=false'));
      expect(beginner, contains('autolock=true'));
    });

}
