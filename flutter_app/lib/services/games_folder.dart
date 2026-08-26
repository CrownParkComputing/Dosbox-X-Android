import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_prefs.dart';

/// Where titles live, and the default when the user has not chosen.
///
/// On iOS there is nothing to choose: the app can only see its own container,
/// and the only way content gets in is the Files app writing into the folder
/// published by UIFileSharingEnabled. So the default is not a convenience
/// there, it is the whole mechanism -- the folder has to exist before the user
/// opens Files, or there is nowhere to drop anything.
class GamesFolder {
  GamesFolder._();

  /// The folder's name, on every platform. Fixed rather than derived so the
  /// user sees the same name in Files on the iPad as in their home directory
  /// on the desktop.
  static const String folderName = 'Retro-DosBox';

  /// Where CD images live, inside the games folder.
  ///
  /// A folder of their own rather than loose among the games, for two
  /// reasons. The library scan skips it, so a shelf of ISOs does not turn
  /// into a shelf of bogus "titles" -- a disc is something you put IN a
  /// machine, not something you launch. And the disc pickers have one place
  /// to browse, so "which discs do I have" has an answer that does not
  /// depend on which game folder someone happened to drop them in.
  static const String cdFolderName = 'CDs';

  /// The user's chosen folder, or the default, created if it does not exist.
  ///
  /// Never returns null: an empty library is a normal state, but "no folder at
  /// all" is not -- it leaves the UI unable to say where to put anything.
  static Future<String> resolve() async {
    final chosen = await AppPrefs.getGamesFolderPath();
    if (chosen != null && chosen.isNotEmpty) {
      return chosen;
    }
    final path = await defaultPath();
    await Directory(path).create(recursive: true);
    return path;
  }

  /// Every storage volume this app can put its games folder on, most
  /// spacious last-resort-free first.
  ///
  /// These are the app's OWN directories on each volume
  /// (`Android/data/<pkg>/files`), which is the one place on a removable card
  /// that needs no permission at all -- not the SAF document tree, whose
  /// paths the engine process frequently cannot open, and not the public
  /// root, which needs all-files access this app deliberately does not ask
  /// for. On a handheld with a full internal partition and a large card,
  /// this is the difference between a library that fits and one that does
  /// not.
  ///
  /// The first entry is the primary (internal) volume, matching
  /// [defaultPath]. Empty on platforms with only one place to put things.
  static Future<List<String>> availableRoots() async {
    if (!Platform.isAndroid) return const <String>[];
    final dirs = await getExternalStorageDirectories();
    if (dirs == null || dirs.length < 2) return const <String>[];
    return dirs.map((d) => p.join(d.path, folderName)).toList(growable: false);
  }

  /// Free space on the volume holding [path], in bytes, or null when it
  /// cannot be determined. Shown beside each choice, because "which of these
  /// two identical-looking paths do I want" is only answerable by size.
  static Future<int?> freeSpaceBytes(String path) async {
    try {
      final out = await Process.run('df', <String>['-k', path]);
      if (out.exitCode != 0) return null;
      final lines = (out.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines.last.split(RegExp(r'\s+'));
      // df -k: Filesystem 1K-blocks Used Available ...
      if (cols.length < 4) return null;
      final kb = int.tryParse(cols[3]);
      return kb == null ? null : kb * 1024;
    } on ProcessException {
      return null;
    }
  }

  /// The CD folder, created if it does not exist.
  ///
  /// Created rather than merely resolved: an empty folder sitting there is
  /// how the user discovers where discs are meant to go. A path named in a
  /// message they have to create by hand is a path most people never create.
  static Future<String> resolveCds() async {
    final path = p.join(await resolve(), cdFolderName);
    await Directory(path).create(recursive: true);
    return path;
  }

  /// How a disc should read in a picker: its path relative to the CD shelf,
  /// so a shelf organised into subfolders still tells you which is which.
  /// Falls back to the bare filename for a disc from anywhere else.
  static String discLabel(String discPath, String cdsRoot) {
    final rel = p.relative(discPath, from: cdsRoot);
    return rel.startsWith('..') ? p.basename(discPath) : rel;
  }

  /// The default location, without creating it.
  ///
  /// iOS/Android: inside the documents directory, which is what
  /// UIFileSharingEnabled publishes to the Files app.
  /// Linux/desktop: the user's home, because a desktop user expects their
  /// games where they can reach them, not buried in an app-support tree.
  static Future<String> defaultPath() async {
    // Android: the app's EXTERNAL files directory, not its documents
    // directory. getApplicationDocumentsDirectory lands in
    // /data/user/0/<pkg>/app_flutter - internal storage, which no PC sees
    // over USB and no file manager shows. A games folder there is one nobody
    // can put games into.
    //
    // The external app folder - Android/data/<pkg>/files - is reachable over
    // USB and needs no permission at all, which is the point: dosbox-x mounts
    // a real directory with `mount c`, so the folder has to be somewhere the
    // app can genuinely read, and shared storage is not that without
    // all-files access.
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) return p.join(external.path, folderName);
      // No external storage at all (no SD emulation): the internal documents
      // directory still works, it is just harder to fill.
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, folderName);
    }
    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, folderName);
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, folderName);
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, folderName);
  }
}
