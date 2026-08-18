import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dosbox_multiplatform/services/zip_importer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Writes a zip containing [files] (path -> contents) into [dir].
File _makeZip(Directory dir, String name, Map<String, String> files) {
  final archive = Archive();
  files.forEach((path, contents) {
    final bytes = contents.codeUnits;
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  final file = File(p.join(dir.path, name));
  file.writeAsBytesSync(ZipEncoder().encode(archive)!);
  return file;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('zipimport'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('unwraps a single top-level directory instead of nesting it', () async {
    // The common shape: CKeen1/KEEN1.EXE. Unpacked naively this becomes
    // Retro-DosBox/CommanderKeen1-shareware/CKeen1/KEEN1.EXE, and the scanner
    // then has to look a level deeper than it does.
    _makeZip(tmp, 'CommanderKeen1-shareware.zip', {
      'CKeen1/KEEN1.EXE': 'MZ',
      'CKeen1/EGAHEAD.CK1': 'data',
    });

    final result = await ZipImporter.importAll(tmp.path);

    expect(result.failed, isEmpty);
    expect(result.imported, hasLength(1));
    expect(p.basename(result.imported.single), 'CKeen1');
    expect(File(p.join(tmp.path, 'CKeen1', 'KEEN1.EXE')).existsSync(), isTrue);
  });

  test('uses the zip name when entries are at the root', () async {
    _makeZip(tmp, 'DIGGER.zip', {'DIGGER.EXE': 'MZ', 'README.TXT': 'hi'});

    final result = await ZipImporter.importAll(tmp.path);

    expect(p.basename(result.imported.single), 'DIGGER');
    expect(File(p.join(tmp.path, 'DIGGER', 'DIGGER.EXE')).existsSync(), isTrue);
  });

  test('strips an uninteresting wrapper directory', () async {
    // "games/" carries no information and would become the title.
    _makeZip(tmp, 'pack.zip', {'games/WOLF3D.EXE': 'MZ'});

    final result = await ZipImporter.importAll(tmp.path);

    expect(p.basename(result.imported.single), 'pack');
    expect(File(p.join(tmp.path, 'pack', 'WOLF3D.EXE')).existsSync(), isTrue);
  });

  test('deletes a zip it consumed', () async {
    final zip = _makeZip(tmp, 'GAME.zip', {'GAME.EXE': 'MZ'});

    await ZipImporter.importAll(tmp.path);

    // Left in place, the same title shows up twice: once as the imported
    // folder and once as an unplayable archive entry.
    expect(zip.existsSync(), isFalse);
  });

  test('keeps a zip it could not read, and reports it', () async {
    final bad = File(p.join(tmp.path, 'broken.zip'))
      ..writeAsBytesSync([0, 1, 2, 3, 4]);

    final result = await ZipImporter.importAll(tmp.path);

    expect(result.imported, isEmpty);
    expect(result.failed, [bad.path]);
    // Nothing is ever destroyed on a bad import.
    expect(bad.existsSync(), isTrue);
  });

  test('refuses entries that would escape the destination', () async {
    // Zip entry names are attacker-controlled text; "../" is the oldest trick
    // there is, and an app that unpacks user-supplied archives has to refuse.
    _makeZip(tmp, 'evil.zip', {
      'GOOD.EXE': 'MZ',
      '../../escaped.txt': 'pwned',
    });

    await ZipImporter.importAll(tmp.path);

    expect(File(p.join(tmp.path, 'evil', 'GOOD.EXE')).existsSync(), isTrue);
    expect(File(p.join(p.dirname(p.dirname(tmp.path)), 'escaped.txt'))
        .existsSync(), isFalse);
  });

  test('importing the same title twice does not overwrite the first', () async {
    _makeZip(tmp, 'GAME.zip', {'GAME/A.EXE': 'first'});
    await ZipImporter.importAll(tmp.path);
    _makeZip(tmp, 'GAME.zip', {'GAME/A.EXE': 'second'});
    await ZipImporter.importAll(tmp.path);

    expect(File(p.join(tmp.path, 'GAME', 'A.EXE')).readAsStringSync(), 'first');
    expect(
        File(p.join(tmp.path, 'GAME (2)', 'A.EXE')).readAsStringSync(), 'second');
  });

  test('an archive of only junk imports nothing and is kept', () async {
    final zip = _makeZip(tmp, 'junk.zip', {'__MACOSX/._x': 'x', '.DS_Store': 'x'});

    final result = await ZipImporter.importAll(tmp.path);

    expect(result.imported, isEmpty);
    expect(result.failed, [zip.path]);
    expect(zip.existsSync(), isTrue);
  });
}

