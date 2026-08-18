import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Unpacks DOS-game zips dropped into the games folder.
///
/// This is how content gets onto an iPad: there is no file picker worth having
/// and no shell, so the user drops a zip into the app's folder in Files and the
/// app imports it on the next scan. The same path works on the desktop, where
/// dropping a zip in is simply less effort than unpacking it first.
class ZipImporter {
  ZipImporter._();

  /// Names that mean "this archive has no useful top level" -- a zip whose
  /// single root directory is one of these is unwrapped a level so the title
  /// does not end up at Retro-DosBox/games/KEEN1.
  static const _uninterestingRoots = {'games', 'dos', 'dosgames', 'game'};

  /// Files that are packaging, not content. A zip containing only these has
  /// nothing in it worth importing.
  static bool _isJunk(String name) {
    final base = p.basename(name);
    return base.startsWith('.') ||
        base.startsWith('__MACOSX') ||
        base.toLowerCase() == 'thumbs.db';
  }

  /// Imports every .zip directly inside [folderPath].
  ///
  /// Returns the titles created. A zip that unpacks successfully is deleted --
  /// it has been consumed, and leaving it means the library shows the same
  /// title twice, once as an archive and once as a folder. A zip that fails is
  /// kept, so nothing is ever destroyed on a bad import.
  ///
  /// The workbench no longer calls this on rescan (archives are launched in
  /// place via ZipRunner, and reading thousands of zips on every scan is
  /// prohibitive). The "Add game" picker still uses it for one-shot imports
  /// where the user picked a single zip and wants it unpacked into the
  /// library.
  static Future<ZipImportResult> importAll(String folderPath) async {
    final root = Directory(folderPath);
    if (!root.existsSync()) {
      return const ZipImportResult(imported: [], failed: []);
    }

    final imported = <String>[];
    final failed = <String>[];

    final zips = root
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => p.extension(f.path).toLowerCase() == '.zip')
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final zip in zips) {
      try {
        final dest = await _importOne(zip, folderPath);
        if (dest == null) {
          failed.add(zip.path);
          continue;
        }
        imported.add(dest);
        await zip.delete();
      } on Object {
        // Broad on purpose: a corrupt zip throws from several layers of the
        // archive package, and every one of them means the same thing to the
        // user. The zip is left on disk either way.
        failed.add(zip.path);
      }
    }

    return ZipImportResult(imported: imported, failed: failed);
  }

  /// Unpacks one zip into a folder beside it. Returns the folder, or null if
  /// the archive held nothing worth importing.
  static Future<String?> _importOne(File zip, String folderPath) async {
    final bytes = await zip.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final files = archive.files.where((f) => f.isFile && !_isJunk(f.name));
    if (files.isEmpty) return null;

    // If everything shares one top-level directory, that directory IS the
    // title and unpacking it as-is would nest it one level too deep.
    final roots = <String>{};
    for (final f in files) {
      final parts = p.split(f.name);
      roots.add(parts.length > 1 ? parts.first : '');
    }
    final singleRoot = roots.length == 1 ? roots.first : '';
    final strip = singleRoot.isNotEmpty &&
        !_uninterestingRoots.contains(singleRoot.toLowerCase());

    final title = strip ? singleRoot : p.basenameWithoutExtension(zip.path);
    final dest = _uniqueDir(p.join(folderPath, title));
    await Directory(dest).create(recursive: true);

    for (final f in files) {
      var rel = f.name;
      if (strip) {
        rel = p.relative(rel, from: singleRoot);
      } else if (singleRoot.isNotEmpty) {
        // A wrapper like games/ that we do not want in the path either.
        rel = p.relative(rel, from: singleRoot);
      }
      if (rel.isEmpty || rel == '.') continue;

      final outPath = p.join(dest, rel);
      // Refuse anything that would escape the destination. Zip entries are
      // attacker-controlled text, and "../../.." is the oldest trick there is.
      if (!p.isWithin(dest, outPath)) continue;

      await Directory(p.dirname(outPath)).create(recursive: true);
      await File(outPath).writeAsBytes(f.content as List<int>);
    }

    return dest;
  }

  /// A path that does not exist yet, suffixing " (2)", " (3)"... as needed, so
  /// importing the same zip twice never overwrites the first import.
  static String _uniqueDir(String preferred) {
    if (!Directory(preferred).existsSync() && !File(preferred).existsSync()) {
      return preferred;
    }
    for (var i = 2; i < 1000; i++) {
      final candidate = '$preferred ($i)';
      if (!Directory(candidate).existsSync() &&
          !File(candidate).existsSync()) {
        return candidate;
      }
    }
    return preferred;
  }
}

class ZipImportResult {
  const ZipImportResult({required this.imported, required this.failed});

  /// Folders created, one per zip.
  final List<String> imported;

  /// Zips that could not be read; left on disk.
  final List<String> failed;

  bool get isEmpty => imported.isEmpty && failed.isEmpty;
}
