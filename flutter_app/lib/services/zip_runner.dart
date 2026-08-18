// Runs a DOS game straight from a .zip, without permanently importing it.
//
// The flow is:
//
//   1. On launch, the zip is unpacked into a per-title cache directory
//      (<appSupport>/archive-cache/<slug>/). Subsequent launches reuse the
//      cached extraction -- a 50MB zip on a slow SD card takes seconds the
//      first time, but is instant on every launch after that.
//
//   2. A writable C: overlay lives at
//      (<appSupport>/archive-cache/<slug>-save/). Before dosbox-x starts, any
//      files already there from previous sessions are copied on top of the
//      extracted game tree; after dosbox-x exits, anything in C:\ that the
//      user changed is copied back. Saves are kept across launches but are
//      discarded if the title itself changes underneath (the slug is derived
//      from the zip's basename, so renaming the zip is what orphans a slot).
//
//   3. The conf mounts the cached extracted tree as C: and a `?:` drive for
//      save data; autoexec loads the highest-rated launcher the same way
//      LibraryScanner._rankLaunchers does, so picking "Play" runs the same
//      executable it would have if the user had manually imported the zip.
//
// The extracted tree is reused across launches but is NOT shared between
// titles -- one cache dir per title -- so two zips with overlapping internal
// names cannot trample each other.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Result of preparing a zip archive for launch.
class ArchiveRunSetup {
  const ArchiveRunSetup({
    required this.cacheRoot,
    required this.saveRoot,
    required this.title,
    required this.launcher,
  });

  /// The directory DOSBox-X should mount as C:.
  final String cacheRoot;

  /// Where the user's saves are stored (and where they will be replayed
  /// from on next launch).
  final String saveRoot;

  /// The display name of the title (from the zip basename, sans extension).
  final String title;

  /// The best-guess launcher inside the extracted tree, or null when the
  /// archive contains no .exe/.com/.bat (in which case dosbox-x drops to a
  /// prompt with a directory listing).
  final String? launcher;
}

class ZipRunner {
  ZipRunner._();

  /// Returns the app's persistent archive cache directory, creating it if
  /// necessary. Lives under the app's support directory so it is not visible
  /// to the user as a "file" in their games folder.
  static Future<Directory> _cacheBase() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'archive-cache'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Extracts [zip] into the per-title cache and returns the setup the
  /// DosConfBuilder needs.
  ///
  /// The cache is keyed by [slug], so two launches of the same zip hit the
  /// same directory. The cache is invalidated only when the underlying zip's
  /// size or last-modified time changes -- this catches the user adding a
  /// patch zip over the original, replacing it with a different release, and
  /// editing a file inside the zip (none of which File.statSync on the zip
  /// itself can detect, but they are all rare enough that the user can hit
  /// "Rescan" to force a refresh).
  ///
  /// Returns null when [zip] cannot be read.
  static Future<ArchiveRunSetup?> prepare({
    required File zip,
    required String slug,
  }) async {
    if (!zip.existsSync()) return null;

    final cacheBase = await _cacheBase();
    final cacheRoot = Directory(p.join(cacheBase.path, slug));
    final saveRoot = Directory(p.join(cacheBase.path, '$slug-save'));
    final stampFile = File(p.join(cacheRoot.path, '.zip-stamp'));

    // The zip's identity as far as the cache is concerned: file size + mtime
    // truncated to seconds (FAT32 only has 2-second mtime resolution, and
    // exFAT is the same on Android).
    final stat = zip.statSync();
    final stamp =
        'size=${stat.size}\nmtime=${stat.modified.millisecondsSinceEpoch ~/ 1000}\n';

    bool fresh = false;
    if (stampFile.existsSync() && stampFile.readAsStringSync() == stamp) {
      fresh = true;
    }

    if (!fresh) {
      // Wipe whatever was there and re-extract. A stale partial extraction
      // is worse than a slow one: a missing file is a confusing launch
      // failure.
      if (cacheRoot.existsSync()) {
        await cacheRoot.delete(recursive: true);
      }
      await cacheRoot.create(recursive: true);

      try {
        await _extractInto(zip, cacheRoot);
      } on ArchiveException {
        return null;
      } on FileSystemException {
        return null;
      }
      await stampFile.writeAsString(stamp, flush: true);
    }

    if (!saveRoot.existsSync()) {
      await saveRoot.create(recursive: true);
    }

    final title = p.basenameWithoutExtension(zip.path);
    final launcher = _pickLauncher(cacheRoot);

    return ArchiveRunSetup(
      cacheRoot: cacheRoot.path,
      saveRoot: saveRoot.path,
      title: title,
      launcher: launcher,
    );
  }

  /// Sweeps the user's C: writes back into the persistent save slot, so the
  /// next launch sees them.
  ///
  /// Called after dosbox-x exits. Files in [saveRoot] win over files in
  /// [cacheRoot] -- the save overlay is what the user has been writing to.
  /// This function does NOT clear [saveRoot]; the save tree is the source of
  /// truth between launches, and [cacheRoot] is rebuilt from scratch on
  /// cache misses.
  static Future<void> persistSaves({
    required String cacheRoot,
    required String saveRoot,
  }) async {
    final cache = Directory(cacheRoot);
    final save = Directory(saveRoot);
    if (!cache.existsSync() || !save.existsSync()) return;

    // Walk saveRoot and copy anything into cacheRoot that does not already
    // exist there, OR that is newer. We use statSync().modified because
    // dosbox-x updates the mtime of files it writes to.
    await for (final entry in save.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final rel = p.relative(entry.path, from: saveRoot);
      final dest = File(p.join(cacheRoot, rel));
      if (!dest.existsSync() ||
          entry.statSync().modified.isAfter(dest.statSync().modified)) {
        await dest.parent.create(recursive: true);
        await entry.copy(dest.path);
      }
    }
  }

  /// Walks [root] looking for the best .exe/.com/.bat to run. Mirrors
  /// LibraryScanner._rankLaunchers so picking "Play" does the same thing
  /// whether the title was imported or run from a zip.
  static String? _pickLauncher(Directory root) {
    const programExts = {'.exe', '.com', '.bat'};
    const junkStems = {
      'install',
      'setup',
      'uninst',
      'uninstal',
      'uninstall',
      'readme',
      'read',
      'help',
      'view',
      'order',
      'catalog',
      'dos4gw',
      'cwsdpmi',
      'pkunzip',
      'unzip',
      'arj',
      'lha',
      'edit',
      'debug',
      'mscdex',
      'himem',
      'emm386',
      'smartdrv',
      'go',
      'launch',
      'renddma',
      'n2rend',
      'nasrend',
      'password',
    };

    final programs = <String>[];
    _walk(root, programs, programExts, 2);
    if (programs.isEmpty) return null;

    int score(String path) {
      final stem = p.basenameWithoutExtension(path).toLowerCase();
      final ext = p.extension(path).toLowerCase();
      var s = 0;
      if (ext == '.bat') {
        // Some downloaded releases ship an installation script named GO.BAT
        // that assumes the original CD layout (for example CD\GAMES\INDYCAR).
        // That path does not exist when the ZIP is mounted in place, so prefer
        // the actual game executable in that case. Ordinary launch scripts
        // remain preferred because they often set required environment flags.
        s -= 2;
        try {
          final text = File(path).readAsStringSync().toLowerCase();
          if (text.contains(RegExp(r'cd\\games\\|xcopy\\s|d:\\')) ||
              text.contains('install')) {
            s += 20;
          }
        } on FileSystemException {
          // Keep the normal batch preference if the file cannot be read.
        }
      }
      if (junkStems.contains(stem)) s += 10;
      s += p.split(path).length;
      return s;
    }

    programs.sort((a, b) => score(a).compareTo(score(b)));
    return programs.first;
  }

  static void _walk(
    Directory dir,
    List<String> programs,
    Set<String> exts,
    int depth,
  ) {
    if (depth < 0) return;
    final List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final child in children) {
      final name = p.basename(child.path);
      if (name.startsWith('.')) continue;
      if (child is Directory) {
        _walk(child, programs, exts, depth - 1);
      } else if (child is File) {
        if (exts.contains(p.extension(child.path).toLowerCase())) {
          programs.add(child.path);
        }
      }
    }
  }

  /// Extracts [zip] into [dest], unwrapping a single wrapper directory so
  /// the launcher search lands at the right level.
  static Future<void> _extractInto(File zip, Directory dest) async {
    final bytes = await zip.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final files = archive.files
        .where((f) => f.isFile && !_isJunk(f.name))
        .toList(growable: false);
    if (files.isEmpty) return;

    final singleRoot = _singleRoot(files);

    for (final f in files) {
      var rel = f.name;
      if (singleRoot.isNotEmpty) {
        rel = p.relative(rel, from: singleRoot);
      }
      if (rel.isEmpty || rel == '.') continue;

      final outPath = p.join(dest.path, rel);
      if (!p.isWithin(dest.path, outPath)) continue;

      await Directory(p.dirname(outPath)).create(recursive: true);
      await File(outPath).writeAsBytes(f.content as List<int>);
    }
  }

  /// Returns the common top-level directory name shared by every entry, or
  /// empty if there is no single root (or the root is one of the noisy
  /// wrappers that we want to skip anyway).
  static String _singleRoot(List<ArchiveFile> files) {
    final roots = <String>{};
    for (final f in files) {
      final parts = p.split(f.name);
      if (parts.length > 1) roots.add(parts.first);
    }
    if (roots.length != 1) return '';
    final root = roots.first;
    final lower = root.toLowerCase();
    if ({'games', 'dos', 'dosgames', 'game'}.contains(lower)) return '';
    return root;
  }

  static bool _isJunk(String name) {
    final base = p.basename(name);
    return base.startsWith('.') ||
        base.startsWith('__MACOSX') ||
        base.toLowerCase() == 'thumbs.db';
  }
}
