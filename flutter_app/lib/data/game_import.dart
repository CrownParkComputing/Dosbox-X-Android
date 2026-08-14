import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// Beginner mode's whole answer to "how do I get a game in?".
///
/// Pick a zip, it becomes a folder on the shelf. Extraction is pure Dart,
/// entry paths are never trusted (a zip can say ../../), and the folder is
/// named after the zip so the shelf reads like a shelf.
class GameImport {
  const GameImport._();

  /// Returns the imported game folder, or null if the user cancelled or the
  /// zip held nothing usable.
  static Future<Directory?> pickAndImport(String gamesDir) async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.any, // .zip is not a UTI Android's picker filters well
    );
    final String? path = picked?.files.single.path;
    if (path == null) return null;
    if (!path.toLowerCase().endsWith('.zip')) {
      // A bare game file is welcome too: it gets a folder of its own.
      final String name = p.basenameWithoutExtension(path);
      final Directory dir = Directory('$gamesDir/$name')
        ..createSync(recursive: true);
      File(path).copySync('${dir.path}/${p.basename(path)}');
      return dir;
    }
    return importZip(File(path), gamesDir);
  }

  static Directory? importZip(File zip, String gamesDir) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    } on Object {
      return null;
    }
    final String name = p.basenameWithoutExtension(zip.path);
    final Directory dir = Directory('$gamesDir/$name');
    bool wrote = false;
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile) continue;
      // Flatten traversal attempts; keep the zip's own folder shape.
      final List<String> parts = p
          .split(entry.name)
          .where((String s) => s != '..' && s != '.' && s.isNotEmpty)
          .toList();
      if (parts.isEmpty) continue;
      final File out = File(p.joinAll(<String>[dir.path, ...parts]));
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(entry.content as List<int>);
      wrote = true;
    }
    return wrote ? dir : null;
  }

  /// The file a beginner means by "the game": prefer an exe named like the
  /// folder, then any .bat that is not install/setup, then the largest exe.
  /// Null means DOS gets a prompt and the player explores - which is also
  /// how it worked in 1993.
  static String? autoExe(Directory game) {
    final List<File> files = game
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    final String folder = p.basename(game.path).toLowerCase();

    String rel(File f) => p.relative(f.path, from: game.path);
    bool isType(File f, String ext) =>
        f.path.toLowerCase().endsWith('.$ext');

    final List<File> exes =
        files.where((File f) => isType(f, 'exe') || isType(f, 'com')).toList();
    for (final File f in exes) {
      if (p.basenameWithoutExtension(f.path).toLowerCase() == folder) {
        return rel(f);
      }
    }
    final List<File> bats = files.where((File f) => isType(f, 'bat')).where(
        (File f) {
      final String n = p.basenameWithoutExtension(f.path).toLowerCase();
      return n != 'install' && n != 'setup';
    }).toList();
    if (bats.length == 1) return rel(bats.first);
    if (exes.isNotEmpty) {
      exes.sort((File a, File b) => b.lengthSync().compareTo(a.lengthSync()));
      final String n =
          p.basenameWithoutExtension(exes.first.path).toLowerCase();
      if (n != 'install' && n != 'setup') return rel(exes.first);
      if (exes.length > 1) return rel(exes[1]);
    }
    return null;
  }
}
