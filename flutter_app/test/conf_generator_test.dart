import 'package:dosboxx_launcher/data/conf_overrides.dart';
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

    test('a game\'s own settings outrank the global ones', () {
      final ConfOverrides global = ConfOverrides.empty()
        ..set('cpu', 'cycles', '3000')
        ..set('sblaster', 'sbtype', 'sb16');
      final ConfOverrides perGame = ConfOverrides.empty()
        ..set('cpu', 'cycles', '500');
      final ConfOverrides merged = ConfOverrides.layered(global, perGame);
      expect(merged.valueOf('cpu', 'cycles'), '500');
      // Global keys the game does not mention still apply.
      expect(merged.valueOf('sblaster', 'sbtype'), 'sb16');
      // Neither input was mutated.
      expect(global.valueOf('cpu', 'cycles'), '3000');
      expect(perGame.valueOf('sblaster', 'sbtype'), isNull);
    });


    test('the core is told to draw no chrome - our menu replaces it', () {
      const DosSettings s = DosSettings(
        machine: DosMachine.dx486,
        mountPath: '/games/x',
        autoexec: 'X.EXE',
      );
      final String conf = ConfGenerator.generate(s);
      expect(conf, contains('showmenu=false'));
      expect(conf, contains('showdetails=false'));
      expect(conf, contains('fullscreen=false'));
      expect(conf, contains('output=surface'));
    });

}
