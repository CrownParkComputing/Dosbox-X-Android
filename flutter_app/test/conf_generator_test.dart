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
}
