import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retro_dosbox/data/game_entry.dart';
import 'package:retro_dosbox/services/app_prefs.dart';
import 'package:retro_dosbox/services/demo_program_service.dart';
import 'package:retro_dosbox/services/library_scanner.dart';
import 'package:retro_dosbox/services/retrodosbox_conf_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('compliance mode defaults on and persists an explicit choice', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await AppPrefs.getComplianceMode(), isTrue);

    await AppPrefs.setComplianceMode(false);
    expect(await AppPrefs.getComplianceMode(), isFalse);
  });

  test(
    'bundled FreeDOS evidence installs without a user games folder',
    () async {
      final temp = await Directory.systemTemp.createTemp('rdbox-demo-test-');
      addTearDown(() => temp.deleteSync(recursive: true));

      final installation = await DemoProgramService.prepare(parent: temp);
      expect(installation.entry.kind, GameKind.floppyImage);
      expect(installation.entry.path, endsWith(DemoProgramService.imageName));
      expect(
        installation.files,
        containsAll(<String>[
          'FREEDOS.IMG',
          'RETRODEM.COM',
          'retro_demo.S',
          'FREEDOS.txt',
          'LICENSE.txt',
          'GPL-2.0.txt',
        ]),
      );

      final image = File(installation.entry.path).readAsBytesSync();
      expect(image.length, 1440 * 1024);
      // Standard x86 boot-sector signature: this is a bootable image, not a
      // renamed archive or a UI-only placeholder.
      expect(image[510], 0x55);
      expect(image[511], 0xaa);
    },
  );

  test('FreeDOS demo is mounted as a floppy and booted from A', () {
    const entry = GameEntry(
      path: '/private/compliance-demo/FREEDOS.IMG',
      kind: GameKind.floppyImage,
      title: DemoProgramService.title,
    );
    final conf = RetroDosboxConfBuilder.build(
      entry: entry,
      settings: const GameSettings(preset: CpuPreset.era80s),
      captureRoot: '/tmp/captures',
      windowed: false,
    );

    expect(
      conf,
      contains(
        'imgmount a "/private/compliance-demo/FREEDOS.IMG" -t floppy -fs none',
      ),
    );
    expect(conf, contains('boot -l a'));
    expect(conf, isNot(contains('imgmount c')));
  });

  test('small IMG files are classified as floppies, not CDs', () async {
    final temp = await Directory.systemTemp.createTemp('rdbox-floppy-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    File(
      '${temp.path}/boot.img',
    ).writeAsBytesSync(List<int>.filled(1440 * 1024, 0));

    final scan = await LibraryScanner.scan(temp.path);
    expect(scan.entries, hasLength(1));
    expect(scan.entries.single.kind, GameKind.floppyImage);
  });
}
