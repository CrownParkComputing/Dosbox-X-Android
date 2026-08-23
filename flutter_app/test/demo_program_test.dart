// The bundled demo is the only thing a fresh install has to run, so the two
// things that matter are that it arrives and that it never tramples the user's
// folder.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:retro_dosbox/services/demo_program.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory games;

  setUp(() {
    games = Directory.systemTemp.createTempSync('dosbox_demo_test');
    // The chosen folder is set explicitly rather than left to the default.
    // On a macOS test host GamesFolder.defaultPath() falls back to $HOME, so
    // a test that relied on the default would write DEMO.COM into the
    // developer's home directory -- which is a rude test and a confusing one.
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.games_folder_path': games.path});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => games.path,
    );
  });

  tearDown(() => games.deleteSync(recursive: true));

  test('the demo image is a valid .COM', () async {
    final bytes = (await rootBundle.load('assets/demo/DEMO.COM'))
        .buffer
        .asUint8List();

    // Loaded flat at 0100h with no header, so a .COM has no magic to check --
    // but it must fit in one segment, and it must start with the mode-set we
    // emit rather than, say, an MZ header from something built by mistake.
    expect(bytes.length, lessThan(0xFF00));
    expect(bytes.sublist(0, 5), <int>[0xB8, 0x03, 0x00, 0xCD, 0x10],
        reason: 'should open with mov ax,0003h / int 10h');
    expect(bytes.first, isNot(0x4D), reason: 'an MZ header is not a .COM');
    // $-terminated, because that is what INT 21h AH=09h stops on. Without it
    // the demo prints whatever follows in memory until it finds one.
    expect(bytes.last, 0x24, reason: r'the message must end with $');
  });

  test('installs onto the shelf when the folder is empty', () async {
    expect(await DemoProgram.install(), isTrue);
    final path = await DemoProgram.installedPath();
    expect(File(path).existsSync(), isTrue);
    expect(p.basename(path), 'DEMO.COM');
  });

  test('installs as a game FOLDER, not a loose program', () async {
    // The scanner indexes .com/.exe only inside a directory -- at the top
    // level it looks for disc images and archives. A loose DEMO.COM installs
    // and mounts perfectly and never appears on the shelf, which is the whole
    // point of the demo.
    await DemoProgram.install();
    final path = await DemoProgram.installedPath();
    expect(p.basename(p.dirname(path)), DemoProgram.folderName);
    expect(Directory(p.dirname(path)).existsSync(), isTrue);
    // ...and it is the games folder that contains that folder, not a deeper
    // nesting the scanner would not descend into.
    expect(p.dirname(p.dirname(path)), games.path);
  });

  test('does not overwrite a file the user already has there', () async {
    final path = await DemoProgram.installedPath();
    await File(path).parent.create(recursive: true);
    File(path).writeAsStringSync('the user put this here');

    expect(await DemoProgram.install(), isFalse);
    expect(File(path).readAsStringSync(), 'the user put this here');
  });
}
