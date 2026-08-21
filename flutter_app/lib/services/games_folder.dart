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
