// Compliance mode makes one promise -- everything on screen came with the app
// -- so the tests are about what the library can and cannot reach.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:retro_dosbox/services/compliance_mode.dart';
import 'package:retro_dosbox/services/demo_program.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('dosbox_compliance_test');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() => support.deleteSync(recursive: true));

  test('off by default', () async {
    expect(await ComplianceMode.isOn(), isFalse);
  });

  test('turning it on stages the demo, so the shelf is never empty', () async {
    await ComplianceMode.set(true);
    expect(await ComplianceMode.isOn(), isTrue);
    final root = await ComplianceMode.rootPath();
    final demo =
        File(p.join(root, DemoProgram.folderName, DemoProgram.fileName));
    expect(demo.existsSync(), isTrue);
    expect(demo.lengthSync(), greaterThan(0));
  });

  test('the demo is staged as a FOLDER the scanner will index', () async {
    // A loose .COM at the root of the scanned directory is invisible: programs
    // count only inside a directory. Getting this wrong produces a compliance
    // mode whose shelf is empty, which demonstrates the opposite of the point.
    await ComplianceMode.stageDemo();
    final root = await ComplianceMode.rootPath();
    final entries = Directory(root).listSync();
    expect(entries, hasLength(1));
    expect(entries.single, isA<Directory>());
    expect(p.basename(entries.single.path), DemoProgram.folderName);
  });

  test('the compliance root is NOT the user documents folder', () async {
    // The Files app publishes Documents; this lives under Application Support,
    // so a user file cannot arrive in the directory compliance mode reads. That
    // separation is the guarantee, not a convention.
    final root = await ComplianceMode.rootPath();
    expect(p.basename(root), 'compliance');
    expect(root, isNot(contains('Documents')));
  });

  test('switching off leaves the staged demo alone', () async {
    await ComplianceMode.set(true);
    final root = await ComplianceMode.rootPath();
    await ComplianceMode.set(false);
    expect(await ComplianceMode.isOn(), isFalse);
    // Kept rather than deleted: switching back on must not have to rewrite it,
    // and nothing else reads this directory.
    expect(
        File(p.join(root, DemoProgram.folderName, DemoProgram.fileName))
            .existsSync(),
        isTrue);
  });
}
