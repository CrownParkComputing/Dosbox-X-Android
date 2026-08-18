// Cross-platform storage-access abstraction backing the setup wizard.
//
// The three platforms this app targets have fundamentally different rules
// for what a foreground app is allowed to touch:
//
//   - Linux: a normal filesystem. Any directory the user's account can read
//     is fair game -- pick a path, scan it recursively.
//   - Android: SAF (Storage Access Framework, reached via
//     ACTION_OPEN_DOCUMENT_TREE). The `file_picker` package's
//     `getDirectoryPath()` wraps SAF's tree picker and returns a real,
//     persisted, readable path on modern Android, so the same "pick a
//     folder, scan it" flow as Linux works here too -- no separate SAF
//     plugin needed.
//   - iOS: sandboxed. There is no such thing as "pick an arbitrary folder
//     and keep reading from it later" -- UIDocumentPickerViewController
//     grants access to the picked items only within that picker session
//     (security-scoped, or for our purposes: read it now or lose it).
//     So iOS steps through `file_picker`'s multi-file *selection* mode and
//     copies each chosen file into the app's own sandboxed Documents
//     directory, where the app then has ordinary permanent access.
//
// The wizard and the rest of the app should only ever talk to
// [StorageAccess.instance] and the [ImportedFile] / [FolderPickResult]
// shapes below -- never branch on Platform.isX outside this file.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Whether a given platform's storage strategy is "pick a folder and scan
/// it" (Linux/Android) or "pick individual files and import them"  (iOS).
enum StorageStrategyKind { folderScan, fileImport }

/// Result of a successful folder pick (Linux/Android strategy).
class FolderPickResult {
  final String path;
  const FolderPickResult(this.path);
}

/// A single item made available to the app, whether by direct filesystem
/// path (Linux/Android, still living wherever the user's folder is) or by
/// having been copied into the app sandbox (iOS).
///
/// [isDirectory] exists because a DOS "game" is very often not a file at
/// all: an installed title is a folder of .exe/.com/.bat plus its data, and
/// that folder is what gets mounted as a drive. Anything downstream that
/// takes an [ImportedFile] therefore has to be able to say "this entry is a
/// directory" rather than assuming a single media file.
class ImportedFile {
  final String displayName;
  final String path;
  final bool isDirectory;
  const ImportedFile({
    required this.displayName,
    required this.path,
    this.isDirectory = false,
  });
}

/// Extensions the wizard's games-folder step and the library scanner treat as
/// DOS media, kept in one place so everything that filters the games folder
/// agrees.
///
/// These are the containers a title arrives in: CD images (mounted with
/// IMGMOUNT as an ISO), floppy images, hard-disk images, and archives (which
/// get extracted to a real folder before mounting). Note what is NOT here --
/// .exe/.com/.bat. Those are the programs *inside* a game folder, and a
/// folder of them is discovered by the scanner as a directory entry, not
/// matched by extension; listing them here would flood the library with one
/// entry per utility in every game's directory.
const List<String> kGameFileExtensions = [
  'iso', 'cue', 'bin', // CD images
  'img', 'ima', 'dsk', // floppy images
  'vhd', // hard-disk images
  'zip', '7z', 'gz', 'tar', 'tgz', 'rar', // archives
];

abstract class StorageAccess {
  static final StorageAccess instance = _createInstance();

  static StorageAccess _createInstance() {
    if (Platform.isIOS) return _IOSFileImportStorage();
    // Linux and Android (and anything else, e.g. dev runs on macOS/Windows)
    // fall back to the folder-scan strategy.
    return _FolderScanStorage();
  }

  /// Whether this platform's games/app folder steps present as a folder
  /// picker ([StorageStrategyKind.folderScan]) or a file importer
  /// ([StorageStrategyKind.fileImport]).
  StorageStrategyKind get kind;

  /// Folder-scan platforms only: open the native directory picker (GTK
  /// dialog on Linux, SAF tree picker on Android) and return the chosen
  /// path, or null if the user cancelled.
  ///
  /// Also the way a single already-installed game directory is added to the
  /// library, not just the way the top-level games folder is chosen.
  Future<FolderPickResult?> pickFolder({required String dialogTitle});

  /// Folder-scan platforms only: recursively list media files under
  /// [folderPath] whose extension is in [extensions] (case-insensitive,
  /// without the leading dot).
  ///
  /// Set [includeDirectories] to also return the immediate subdirectories of
  /// [folderPath] as entries with [ImportedFile.isDirectory] set. That is how
  /// installed-to-a-folder games get seen at all -- they have no media file
  /// to match on.
  Future<List<ImportedFile>> scanFolder(String folderPath,
      {List<String> extensions = kGameFileExtensions,
      bool includeDirectories = false});

  /// File-import platforms only: open the native document/file picker
  /// (UIDocumentPickerViewController on iOS) restricted to [extensions],
  /// copy each chosen file into [destinationSubdir] under the app's
  /// sandboxed Documents directory, and return the copies. Returns an
  /// empty list if the user cancelled or picked nothing.
  Future<List<ImportedFile>> pickAndImportFiles({
    required String destinationSubdir,
    List<String> extensions = kGameFileExtensions,
  });

  /// File-import platforms only: list items already imported into
  /// [destinationSubdir] from a previous session, so the wizard/Paths
  /// screen can show "N games imported" without re-picking.
  ///
  /// Directories are included: an imported archive that has since been
  /// extracted in place is a folder, and it is still a game.
  Future<List<ImportedFile>> listImported(String destinationSubdir);
}

/// Linux + Android: pick a real directory, scan it directly. `file_picker`'s
/// `getDirectoryPath()` uses a native GTK dialog on Linux and Android's SAF
/// tree picker under the hood, and on modern Android (API 30+, which is all
/// this app targets -- see android/app/build.gradle.kts minSdk) hands back
/// a filesystem path the app can read from directly via `dart:io`, so no
/// separate SAF/content-URI plumbing (e.g. `shared_storage`) was needed.
class _FolderScanStorage extends StorageAccess {
  @override
  StorageStrategyKind get kind => StorageStrategyKind.folderScan;

  @override
  Future<FolderPickResult?> pickFolder({required String dialogTitle}) async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: dialogTitle,
    );
    if (path == null) return null;
    return FolderPickResult(path);
  }

  @override
  Future<List<ImportedFile>> scanFolder(String folderPath,
      {List<String> extensions = kGameFileExtensions,
      bool includeDirectories = false}) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return const [];
    final wanted = extensions.map((e) => e.toLowerCase()).toSet();
    final results = <ImportedFile>[];
    for (final entry in dir.listSync(recursive: true, followLinks: false)) {
      if (entry is Directory) {
        // Only the top level: a game folder's own subdirectories (SAVE,
        // SOUND, DATA...) are part of that game, not separate entries.
        if (!includeDirectories) continue;
        if (p.dirname(entry.path) != dir.path) continue;
        results.add(ImportedFile(
          displayName: p.basename(entry.path),
          path: entry.path,
          isDirectory: true,
        ));
        continue;
      }
      if (entry is! File) continue;
      final ext = p.extension(entry.path).replaceFirst('.', '').toLowerCase();
      if (!wanted.contains(ext)) continue;
      results.add(ImportedFile(
        displayName: p.basename(entry.path),
        path: entry.path,
      ));
    }
    return results;
  }

  @override
  Future<List<ImportedFile>> pickAndImportFiles({
    required String destinationSubdir,
    List<String> extensions = kGameFileExtensions,
  }) {
    throw UnsupportedError(
        'pickAndImportFiles is an iOS-only strategy; this platform uses pickFolder/scanFolder.');
  }

  @override
  Future<List<ImportedFile>> listImported(String destinationSubdir) async =>
      const [];
}

/// iOS: sandboxed, no persistent folder access. Steps through
/// UIDocumentPickerViewController (via file_picker's multi-select file
/// mode) and copies each picked file into the app's own Documents
/// directory, where it stays available across launches without needing a
/// security-scoped bookmark.
///
/// This is also why the iOS flow is file-only: a folder-installed DOS game
/// cannot be handed over by the document picker as a tree the app keeps
/// access to, so on iOS a game arrives as an image or an archive and becomes
/// a folder in the sandbox only after the app extracts it itself.
class _IOSFileImportStorage extends StorageAccess {
  @override
  StorageStrategyKind get kind => StorageStrategyKind.fileImport;

  @override
  Future<FolderPickResult?> pickFolder({required String dialogTitle}) {
    throw UnsupportedError(
        'pickFolder is a folder-scan-only strategy; iOS uses pickAndImportFiles.');
  }

  @override
  Future<List<ImportedFile>> scanFolder(String folderPath,
      {List<String> extensions = kGameFileExtensions,
      bool includeDirectories = false}) {
    throw UnsupportedError(
        'scanFolder is a folder-scan-only strategy; iOS uses listImported.');
  }

  Future<Directory> _destinationDir(String destinationSubdir) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, destinationSubdir));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  @override
  Future<List<ImportedFile>> pickAndImportFiles({
    required String destinationSubdir,
    List<String> extensions = kGameFileExtensions,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    if (result == null || result.files.isEmpty) return const [];

    final destDir = await _destinationDir(destinationSubdir);
    final imported = <ImportedFile>[];
    for (final picked in result.files) {
      final sourcePath = picked.path;
      if (sourcePath == null) continue; // web-only field, never null on iOS
      final source = File(sourcePath);
      if (!source.existsSync()) continue;
      final destPath = p.join(destDir.path, picked.name);
      try {
        source.copySync(destPath);
        imported.add(ImportedFile(displayName: picked.name, path: destPath));
      } catch (_) {
        // Leave this file out of the result rather than aborting the whole
        // import; the wizard reports how many succeeded.
      }
    }
    return imported;
  }

  @override
  Future<List<ImportedFile>> listImported(String destinationSubdir) async {
    final dir = await _destinationDir(destinationSubdir);
    final results = <ImportedFile>[];
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is Directory) {
        results.add(ImportedFile(
          displayName: p.basename(entry.path),
          path: entry.path,
          isDirectory: true,
        ));
        continue;
      }
      if (entry is! File) continue;
      results.add(ImportedFile(
        displayName: p.basename(entry.path),
        path: entry.path,
      ));
    }
    return results;
  }
}
