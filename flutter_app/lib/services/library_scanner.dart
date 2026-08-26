// Turns a games folder into a list of launchable titles.
//
// This is where the DOS front end diverges most from the VICE one. Scanning for
// C64 media is a file-extension filter: a .d64 is a title, full stop. A DOS
// library is structural -- the unit is normally a DIRECTORY containing an
// installed game, with the executables, data and any disc images inside it. So
// this scanner classifies directories, and only falls back to treating loose
// files as titles when they are self-contained (a CD image, a bootable disk
// image, an un-imported archive).
import 'dart:isolate';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/game_entry.dart';
import 'games_folder.dart';
import 'disk_image.dart';

/// Extensions that make a loose file a title in its own right.
const Set<String> _discExtensions = {'.iso', '.cue', '.bin'};

/// Disk images. These are ambiguous: a .img can be a floppy, a bootable hard
/// disk, or a raw CD. Size is used to disambiguate -- see [_classifyImage].
const Set<String> _imageExtensions = {
  '.img', '.ima', '.dsk', // ambiguous: floppy or hard disk, decided by size
  '.vhd', '.hdd', '.hdi', // always hard disks, whatever their length
};

const Set<String> _archiveExtensions = {
  '.zip',
  '.7z',
  '.gz',
  '.tar',
  '.tgz',
  '.rar',
};

/// Programs that can be launched inside a game folder.
const Set<String> _programExtensions = {'.exe', '.com', '.bat'};

/// Executable names that are almost never the game itself. Filtered out of the
/// launcher candidates so "play" picks something sensible, but deliberately
/// still offered in the "pick a program" list, because running the installer or
/// the sound setup is a thing users legitimately need to do.
const Set<String> _nonGameProgramStems = {
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
};

/// A file below this size cannot be a bootable hard disk image. 4MB is chosen
/// to sit comfortably above the largest floppy format (2.88MB) and far below
/// any realistic DOS or Win9x hard disk image.
const int _minHardDiskImageBytes = 4 * 1024 * 1024;

class LibraryScanResult {
  final List<GameEntry> entries;

  /// Paths that matched but could not be read. Surfaced rather than silently
  /// dropped because on Android this is the signature of a scoped-storage
  /// permission problem, and a library that is quietly half-empty is far more
  /// confusing than one that says so.
  final List<String> unreadable;

  const LibraryScanResult({required this.entries, required this.unreadable});

  bool get isEmpty => entries.isEmpty;
}

class LibraryScanner {
  LibraryScanner._();

  /// Scans [folderPath] one level deep for titles.
  ///
  /// One level, not recursive: the immediate children of the games folder are
  /// the titles, and everything below that belongs to a title. Recursing would
  /// turn a game's own SAVE/, DATA/ and CDROM/ subdirectories into bogus
  /// library entries.
  static Future<LibraryScanResult> scan(String folderPath) =>
      // A background isolate, not chunked yields on the UI isolate: the
      // sync directory walks below still burned UI-thread CPU between
      // yields, and the deep CD-image recursion never yielded at all --
      // which is the frame-drop class the Amiga live release taught us to
      // move off the UI thread entirely.
      Isolate.run(() => _scanOnIsolate(folderPath));

  static Future<LibraryScanResult> _scanOnIsolate(String folderPath) async {
    final root = Directory(folderPath);
    if (!root.existsSync()) {
      return const LibraryScanResult(entries: [], unreadable: []);
    }

    final entries = <GameEntry>[];
    final unreadable = <String>[];

    final List<FileSystemEntity> children;
    try {
      children = root.listSync(followLinks: false);
    } on FileSystemException {
      return LibraryScanResult(entries: const [], unreadable: [folderPath]);
    }

    var processed = 0;
    for (final child in children) {
      final name = p.basename(child.path);
      // Hidden entries, plus the '.c' directory this app creates to hold the
      // writable C: drives it makes for CD titles.
      if (name.startsWith('.')) continue;
      // The CD shelf. Its contents are discs to put in a drive, not titles to
      // launch, and listing them as titles would bury the games under every
      // ISO the user owns.
      if (name == GamesFolder.cdFolderName) continue;

      try {
        if (child is Directory) {
          final entry = await _classifyDirectory(child);
          if (entry != null) {
            entries.add(entry);
          } else {
            // A directory that classifies as nothing -- no .exe/.com/.bat,
            // no bootable image, no disc. Peek one level deeper: many
            // real-world games folders are organised as
            //   games/<archive-set>/<actual zips and ISOs>
            // and the inner zips are the titles the user wants to see.
            for (final grand in _listDirect(child)) {
              if (grand is File) {
                final gen = await _classifyFile(grand);
                if (gen != null) entries.add(gen);
              }
            }
          }
        } else if (child is File) {
          // Top-level files: cheap to classify by extension only, because
          // nothing in the games folder itself is a bootable hard-disk
          // image that needs the size check. Doing the full _classifyFile
          // here costs a File.statSync() per archive on Android, which
          // goes through the SAF binder to MediaProvider and dominates the
          // scan time for a 3,000-zip folder.
          final ext = p.extension(child.path).toLowerCase();
          final title = p.basenameWithoutExtension(child.path);
          if (_discExtensions.contains(ext) ||
              _archiveExtensions.contains(ext)) {
            entries.add(
              GameEntry(
                path: child.path,
                kind:
                    ext == '.cue' || ext == '.iso' || ext == '.bin'
                    ? GameKind.discImage
                    : GameKind.archive,
                title: title,
              ),
            );
          } else if (_imageExtensions.contains(ext)) {
            // .vhd/.hdd/etc still need the size check to know if they are
            // bootable. There are rarely many of these at the top level,
            // so the cost is bounded.
            final entry = await _classifyFile(child);
            if (entry != null) entries.add(entry);
          }
        }
      } on FileSystemException {
        unreadable.add(child.path);
      }

      // Yield every so often so the UI stays responsive on a folder with
      // thousands of entries. The cost of a microtask is invisible next
      // to a single SAF binder call, but it lets Flutter repaint the
      // spinner frame instead of going black.
      processed++;
      if (processed % 250 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    entries.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return LibraryScanResult(entries: entries, unreadable: unreadable);
  }

  /// Every CD image under [root], for the "which disc is in the drive"
  /// pickers.
  ///
  /// Recursive, so the CD shelf can be organised into subfolders and still
  /// browse as one list.
  ///
  /// Deliberately a folder walk rather than a file picker over the whole
  /// device: on Android an arbitrary path handed back by the document picker
  /// is frequently one the engine process cannot open (it runs in :dosbox and
  /// has no claim on the caller's URI permission), and a disc that mounts as
  /// nothing is worse than one that was never offered. Anything under the
  /// games folder is readable by construction.
  static Future<List<String>> findDiscImages(String root) async {
    final dir = Directory(root);
    if (!dir.existsSync()) return const <String>[];
    final found = <String>[];
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (p.basename(e.path).startsWith('.')) continue;
        if (_discExtensions.contains(p.extension(e.path).toLowerCase())) {
          found.add(e.path);
        }
      }
    } on FileSystemException {
      // A partly-unreadable tree still yields whatever was reachable.
    }
    found.sort((a, b) => p.basename(a).toLowerCase().compareTo(
          p.basename(b).toLowerCase(),
        ));
    return found;
  }

  /// Classifies a single path the way a scan would, without walking a whole
  /// games folder to reach it.
  ///
  /// Exposed for the host-side boot tests, which need the app's own verdict
  /// on one image rather than a second opinion written alongside them.
  static Future<GameEntry?> classify(String path) async {
    switch (FileSystemEntity.typeSync(path)) {
      case FileSystemEntityType.directory:
        return _classifyDirectory(Directory(path));
      case FileSystemEntityType.file:
        return _classifyFile(File(path));
      default:
        return null;
    }
  }

  /// A directory is a DOS game if it contains a runnable program anywhere in
  /// its first few levels, or a bootable image, or discs.
  static Future<GameEntry?> _classifyDirectory(Directory dir) async {
    final programs = <String>[];
    final discs = <String>[];
    final images = <File>[];

    _walk(dir, 3, programs, discs, images);

    // A folder holding nothing but a bootable image is a boot title, not a DOS
    // folder -- there is no C: to mount, the image IS the disk.
    if (programs.isEmpty) {
      for (final image in images) {
        return GameEntry(
          path: image.path,
          kind: await _isHardDiskImage(image)
              ? GameKind.bootImage
              : GameKind.floppyImage,
          title: p.basename(dir.path),
          discs: discs,
        );
      }
    }

    // Discs but no programs: playable/installable from the disc.
    if (programs.isEmpty && discs.isNotEmpty) {
      return GameEntry(
        path: discs.first,
        kind: GameKind.discImage,
        title: p.basename(dir.path),
        discs: discs.skip(1).toList(growable: false),
      );
    }

    if (programs.isEmpty) return null;

    return GameEntry(
      path: dir.path,
      kind: GameKind.dosFolder,
      title: p.basename(dir.path),
      launchers: _rankLaunchers(programs),
      discs: discs,
    );
  }

  static Future<GameEntry?> _classifyFile(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    final title = p.basenameWithoutExtension(file.path);

    if (_discExtensions.contains(ext)) {
      return GameEntry(path: file.path, kind: GameKind.discImage, title: title);
    }
    if (_imageExtensions.contains(ext)) {
      return GameEntry(
        path: file.path,
        kind: await _isHardDiskImage(file)
            ? GameKind.bootImage
            : GameKind.floppyImage,
        title: title,
      );
    }
    if (_archiveExtensions.contains(ext)) {
      return GameEntry(path: file.path, kind: GameKind.archive, title: title);
    }
    return null;
  }

  /// Collects programs, discs and disk images from [dir], up to [depth] levels.
  ///
  /// Bounded rather than unlimited: some titles ship a full CD tree in a
  /// subdirectory, and walking every level of it to find executables is slow
  /// on Android's storage layer for no benefit -- a game's own launcher lives
  /// near the top.
  static void _walk(
    Directory dir,
    int depth,
    List<String> programs,
    List<String> discs,
    List<File> images,
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
        _walk(child, depth - 1, programs, discs, images);
      } else if (child is File) {
        final ext = p.extension(child.path).toLowerCase();
        if (_programExtensions.contains(ext)) {
          programs.add(child.path);
        } else if (_discExtensions.contains(ext)) {
          discs.add(child.path);
        } else if (_imageExtensions.contains(ext)) {
          images.add(child);
        }
      }
    }
  }

  /// Orders launcher candidates so the first is the best guess at "the game".
  ///
  /// Ranking rather than filtering: a wrong guess is recoverable (the user
  /// picks another program), but hiding the only working executable is not.
  static List<String> _rankLaunchers(List<String> programs) {
    int score(String path) {
      final stem = p.basenameWithoutExtension(path).toLowerCase();
      final ext = p.extension(path).toLowerCase();
      var s = 0;
      // Shipped .bat files usually set up the environment (sound variables, CD
      // paths) that the bare executable assumes has already happened.
      if (ext == '.bat') {
        // Reject installer-style scripts that refer to the original CD layout
        // (for example CD\GAMES\INDYCAR). The mounted game directory cannot
        // satisfy those absolute paths, while the real executable can run.
        s -= 2;
        try {
          final text = File(path).readAsStringSync().toLowerCase();
          if (text.contains(RegExp(r'cd\\games\\|xcopy\\s|d:\\')) ||
              text.contains('install')) {
            s += 20;
          }
        } on FileSystemException {
          // Preserve the normal batch preference when unreadable.
        }
      }
      if (_nonGameProgramStems.contains(stem) ||
          stem == 'go' ||
          stem == 'launch' ||
          stem == 'renddma' ||
          stem == 'n2rend' ||
          stem == 'nasrend' ||
          stem == 'password') {
        s += 10;
      }
      // Shallower is more likely to be the entry point.
      s += p.split(path).length;
      return s;
    }

    final sorted = [...programs]
      ..sort((a, b) {
        final byScore = score(a).compareTo(score(b));
        if (byScore != 0) return byScore;
        return p
            .basename(a)
            .toLowerCase()
            .compareTo(p.basename(b).toLowerCase());
      });
    return sorted;
  }

  /// Lists the immediate children of [dir], skipping hidden entries.
  /// Used by the scan to peek one level into a directory that classified as
  /// nothing, so archive-only subdirectories are surfaced as loose files.
  static List<FileSystemEntity> _listDirect(Directory dir) {
    try {
      return dir
          .listSync(followLinks: false)
          .where((e) => !p.basename(e.path).startsWith('.'))
          .toList();
    } on FileSystemException {
      return const [];
    }
  }

  /// Whether an ambiguous image file is a hard disk image (bootable) rather
  /// than a floppy or CD image.
  ///
  /// Size is the only cheap signal available for the ambiguous extensions.
  /// Reading the partition table would be more accurate, and is worth doing
  /// once the FAT32/MBR reader is ported over from the Java Fat32Reader --
  /// until then a large .img is treated as bootable, which is right far more
  /// often than not. .vhd and friends skip the test entirely: a dynamic VHD
  /// that has not been filled yet is a few kilobytes long and would fail it
  /// while still being a hard disk.
  static Future<bool> _isHardDiskImage(File file) async {
    return DiskImage.isHardDisk(
      file.path,
      minHardDiskBytes: _minHardDiskImageBytes,
    );
  }
}
