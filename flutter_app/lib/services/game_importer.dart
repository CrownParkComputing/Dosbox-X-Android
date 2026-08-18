// Adds a single new title to the library.
//
// The library scanner is read-only: it walks the games folder and reports
// what it finds. There is no path through it that adds a file the user did
// not already have. This module closes that gap: a "Add game" button in the
// library grid calls into here with the path the user picked, and the result
// is a fresh title in the games folder the next time the scanner runs.
//
// The implementation handles two kinds of source:
//
//   - A zip archive. The existing ZipImporter is the pure unpacker, but its
//     destination is the top-level games folder. We reuse that logic by
//     copying the zip into the games folder first, then handing it to
//     ZipImporter.importAll, which picks it up alongside anything else that
//     was already there.
//
//   - A directory. Mounted-in-place games are directories -- an installed
//     copy of DOOM, a CD-ROM with INSTALL.EXE, etc. The user points FilePicker
//     at one and we copy it whole into the games folder. The library scanner
//     then sees the directory one level deep and turns it into a title.
//
// On every failure path the source is left untouched, so a bad copy or a
// broken zip is repeatable.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'zip_importer.dart';

class GameImporter {
  GameImporter._();

  /// Imports a single source file or directory into [gamesFolder].
  ///
  /// Returns the path of the resulting title (a folder inside the games
  /// folder) on success, or null if the import failed. A failure leaves both
  /// the source and the games folder untouched, so the user can retry.
  static Future<String?> importOne(String sourcePath, String gamesFolder) async {
    final src = FileSystemEntity.typeSync(sourcePath) ==
            FileSystemEntityType.directory
        ? Directory(sourcePath)
        : File(sourcePath);

    if (!src.existsSync()) return null;

    final baseName = p.basename(sourcePath);
    final ext = p.extension(sourcePath).toLowerCase();

    if (src is Directory) {
      // Copy the directory into the games folder, then hand off to the
      // library scanner.
      final dest = _uniqueDest(p.join(gamesFolder, baseName));
      final copied = await _copyDirectory(src, dest);
      if (!copied) return null;
      return dest;
    }

    if (ext == '.zip') {
      // Drop the zip beside anything else the games folder holds, then let
      // ZipImporter unpack it through the same path it already uses for
      // zips that "appeared in the folder" by File Sharing.
      final dest = File(p.join(gamesFolder, baseName));
      try {
        await (src as File).copy(dest.path);
      } on FileSystemException {
        return null;
      }
      final importResult = await ZipImporter.importAll(gamesFolder);
      if (importResult.failed.contains(dest.path)) {
        return null;
      }
      // The zip was deleted by ZipImporter on success; its folder is the
      // imported title. The folder name is the zip's basename without
      // the .zip extension.
      final folder = p.setExtension(baseName, '');
      return p.join(gamesFolder, folder);
    }

    // A single loose file (.iso, .cue, .bin, .img, .dsk, .vhd) is a title
    // in its own right. Copy it into the games folder so the library
    // scanner picks it up like any other loose file.
    final dest = _uniqueDest(p.join(gamesFolder, baseName));
    try {
      await (src as File).copy(dest);
    } on FileSystemException {
      return null;
    }
    return dest;
  }

  /// Returns a path in [dir] that does not yet exist. If [base] is taken,
  /// tries `<base> (2)`, `<base> (3)`, and so on. Never returns a path that
  /// collides, so the user can import the same source twice without the
  /// second copy overwriting the first.
  static String _uniqueDest(String path) {
    if (!FileSystemEntity.typeSync(path, followLinks: false).existsOr()) {
      return path;
    }
    final dir = p.dirname(path);
    final base = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    for (var i = 2; i < 1000; i++) {
      final candidate = p.join(dir, '$base ($i)$ext');
      if (!FileSystemEntity.typeSync(candidate, followLinks: false)
          .existsOr()) {
        return candidate;
      }
    }
    // Fall back to the requested path; the copy will fail loudly.
    return path;
  }

  /// Recursive copy. Returns false on any failure so the caller can leave
  /// the destination half-written and pull it back.
  static Future<bool> _copyDirectory(Directory src, String destPath) async {
    final dest = Directory(destPath);
    if (dest.existsSync()) {
      // _uniqueDest should have prevented this, but defend anyway.
      return false;
    }
    try {
      await dest.create(recursive: true);
    } on FileSystemException {
      return false;
    }
    final entries = src.listSync(recursive: false, followLinks: false);
    for (final entry in entries) {
      final name = p.basename(entry.path);
      final target = p.join(destPath, name);
      if (entry is Directory) {
        if (!await _copyDirectory(entry, target)) return false;
      } else if (entry is File) {
        try {
          await entry.copy(target);
        } on FileSystemException {
          return false;
        }
      }
    }
    return true;
  }
}

extension on FileSystemEntityType {
  /// dart:io's FileSystemEntityType sentinel is "not found" rather than a
  /// thrown exception, which is verbose to test for in-line. This wrapper
  /// returns true for any of the three real types and false for the not-found
  /// sentinel, so the importer's collision check reads naturally.
  bool existsOr() => this != FileSystemEntityType.notFound;
}
