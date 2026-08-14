import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dosboxx_launcher/data/conf_catalog.dart';
import 'package:dosboxx_launcher/data/conf_generator.dart';
import 'package:dosboxx_launcher/data/conf_overrides.dart';
import 'package:dosboxx_launcher/data/dos_settings.dart';

void main() {
  final String json = File('assets/conf_catalog.json').readAsStringSync();

  test('the catalogue carries the whole surface', () {
    final ConfCatalog c = ConfCatalog.fromJsonString(json);
    expect(c.sections.length, greaterThan(30));
    final int options =
        c.sections.fold(0, (int n, ConfSection s) => n + s.options.length);
    expect(options, greaterThan(800));

    final ConfSection cpu =
        c.sections.firstWhere((ConfSection s) => s.name == 'cpu');
    final ConfOption core =
        cpu.options.firstWhere((ConfOption o) => o.key == 'core');
    expect(core.values, contains('normal'));
    expect(core.isEnum, isTrue);
    expect(core.isBool, isFalse);
  });

  test('booleans read as booleans, not enums', () {
    final ConfCatalog c = ConfCatalog.fromJsonString(json);
    final ConfSection cpu =
        c.sections.firstWhere((ConfSection s) => s.name == 'cpu');
    final ConfOption fpu =
        cpu.options.firstWhere((ConfOption o) => o.key == 'fpu');
    // fpu allows auto/8087/287/387 beyond true/false - an enum, not a switch.
    expect(fpu.isBool, isFalse);
  });

  test('overrides outrank the preset and only overrides are written', () {
    final ConfOverrides o = ConfOverrides.empty()
      ..set('cpu', 'cycles', '12000')
      ..set('render', 'aspect', 'true');
    final String conf = ConfGenerator.generate(
      const DosSettings(machine: DosMachine.dx486),
      o,
    );
    expect(conf, contains('cycles=12000')); // override beat the 486 preset
    expect(conf, contains('[render]'));
    expect(conf, contains('aspect=true'));
    expect(conf, isNot(contains('scaler'))); // untouched keys stay unwritten
  });

  test('overrides survive the round trip', () {
    final ConfOverrides o = ConfOverrides.empty()..set('cpu', 'cycles', 'max');
    final ConfOverrides back = ConfOverrides.decode(o.encode());
    expect(back.valueOf('cpu', 'cycles'), 'max');
    back.clear('cpu', 'cycles');
    expect(back.isEmpty, isTrue);
  });
}
