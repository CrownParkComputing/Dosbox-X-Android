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
      final Directory dir =
          _uniqueDir(gamesDir, p.basenameWithoutExtension(path));
      File(path).copySync('${dir.path}/${dosName(p.basename(path))}');
      return dir;
    }
    return importZip(File(path), gamesDir);
  }

  /// The folder flavour of [pickAndImport].
  static Future<Directory?> pickAndImportFolder(String gamesDir) async {
    final String? src = await FilePicker.platform.getDirectoryPath();
    if (src == null) return null;
    return importFolder(src, gamesDir);
  }

  /// A folder brought in whole - a game already unpacked somewhere else.
  /// Copies rather than moves: the source is the user's, wherever it lives.
  static Directory? importFolder(String srcPath, String gamesDir) {
    final Directory src = Directory(srcPath);
    if (!src.existsSync()) return null;
    final Directory dir =
        _uniqueDir(gamesDir, p.basename(srcPath.replaceAll(RegExp(r'/+$'), '')));
    bool wrote = false;
    final Map<String, String> memo = <String, String>{};
    final Set<String> taken = <String>{};
    try {
      for (final FileSystemEntity e in src.listSync(recursive: true)) {
        if (e is! File) continue;
        final String rel = p.joinAll(dosPath(
            p.split(p.relative(e.path, from: src.path)), memo, taken));
        final File out = File(p.join(dir.path, rel));
        out.parent.createSync(recursive: true);
        e.copySync(out.path);
        wrote = true;
      }
    } on FileSystemException {
      // Partial copies stand; the user sees what arrived and can retry.
    }
    return wrote ? dir : null;
  }

  /// DOS 8.3-safe file/dir name. DOS 5 has no long filenames: a name with a
  /// space or over 8+3 characters is unreachable from the prompt ("boulder
  /// dash.exe" -> Bad command or filename), so every path segment inside a
  /// game folder is sanitised at import. The game folder itself keeps its
  /// long shelf name - only its contents must be DOS-legal, because that is
  /// what gets mounted.
  static String dosName(String segment) {
    String stem = segment;
    String ext = '';
    final int dot = segment.lastIndexOf('.');
    if (dot > 0) {
      stem = segment.substring(0, dot);
      ext = segment.substring(dot + 1);
    }
    String clean(String s, int max) {
      final String kept =
          s.replaceAll(RegExp(r'[^A-Za-z0-9_\-~]'), '').toUpperCase();
      return kept.substring(0, kept.length > max ? max : kept.length);
    }
    final String cStem = clean(stem, 8);
    final String cExt = clean(ext, 3);
    final String name = cStem.isEmpty ? 'X' : cStem;
    return cExt.isEmpty ? name : '$name.$cExt';
  }

  /// [dosName] over every segment of a relative path. The same original
  /// directory always maps to the same sanitised directory (memo), and two
  /// different originals that truncate to the same short name get a digit
  /// bumped into the stem (HELLO WORLD.TXT vs HELLOWORLD.TXT).
  static List<String> dosPath(
      List<String> parts, Map<String, String> memo, Set<String> taken) {
    String origPrefix = '';
    String sanPrefix = '';
    final List<String> out = <String>[];
    for (final String part in parts) {
      origPrefix =
          origPrefix.isEmpty ? part.toLowerCase() : '$origPrefix/${part.toLowerCase()}';
      final String? seen = memo[origPrefix];
      if (seen != null) {
        sanPrefix = seen;
        out.add(seen.split('/').last);
        continue;
      }
      String seg = dosName(part);
      String candidate = sanPrefix.isEmpty ? seg : '$sanPrefix/$seg';
      int n = 2;
      while (taken.contains(candidate.toLowerCase())) {
        final int dot = seg.lastIndexOf('.');
        final String stem = dot > 0 ? seg.substring(0, dot) : seg;
        final String ext = dot > 0 ? seg.substring(dot) : '';
        final String digits = '$n';
        final String base = stem.length + digits.length > 8
            ? stem.substring(0, 8 - digits.length)
            : stem;
        final String bumped = '$base$digits$ext';
        candidate = sanPrefix.isEmpty ? bumped : '$sanPrefix/$bumped';
        n++;
      }
      taken.add(candidate.toLowerCase());
      memo[origPrefix] = candidate;
      sanPrefix = candidate;
      out.add(candidate.split('/').last);
    }
    return out;
  }

  /// games/name, or name-2, -3... - an import must never overwrite a
  /// game that shares a title.
  static Directory _uniqueDir(String gamesDir, String name) {
    Directory dir = Directory('$gamesDir/$name');
    int n = 2;
    while (dir.existsSync() && dir.listSync().isNotEmpty) {
      dir = Directory('$gamesDir/$name-${n++}');
    }
    dir.createSync(recursive: true);
    return dir;
  }

  static Directory? importZip(File zip, String gamesDir) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    } on Object {
      return null;
    }
    final Directory dir =
        _uniqueDir(gamesDir, p.basenameWithoutExtension(zip.path));
    bool wrote = false;
    final Map<String, String> memo = <String, String>{};
    final Set<String> taken = <String>{};
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile) continue;
      // Flatten traversal attempts; keep the zip's own folder shape.
      final List<String> parts = p
          .split(entry.name)
          .where((String s) => s != '..' && s != '.' && s.isNotEmpty)
          .toList();
      if (parts.isEmpty) continue;
      final File out =
          File(p.joinAll(<String>[dir.path, ...dosPath(parts, memo, taken)]));
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(entry.content as List<int>);
      wrote = true;
    }
    return wrote ? dir : null;
  }

  /// Every runnable thing in the game folder, shallowest first - what the
  /// which-exe question lists.
  static List<String> candidateExes(Directory game) {
    final List<File> files =
        game.listSync(recursive: true).whereType<File>().where((File f) {
      final String l = f.path.toLowerCase();
      return l.endsWith('.exe') || l.endsWith('.com') || l.endsWith('.bat');
    }).toList()
          ..sort((File a, File b) {
            final int depth = p.split(a.path).length - p.split(b.path).length;
            return depth != 0 ? depth : a.path.compareTo(b.path);
          });
    return <String>[
      for (final File f in files) p.relative(f.path, from: game.path),
    ];
  }

  /// The remembered answer to "which exe", stored inside the game's own
  /// folder so it travels with the game and dies with the game.
  static File _choiceFile(Directory game) =>
      File('${game.path}/.dosboxx_exe');

  static String? rememberedExe(Directory game) {
    final File f = _choiceFile(game);
    if (!f.existsSync()) return null;
    final String rel = f.readAsStringSync().trim();
    return File(p.join(game.path, rel)).existsSync() ? rel : null;
  }

  static void rememberExe(Directory game, String rel) =>
      _choiceFile(game).writeAsStringSync(rel);

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
