import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One file the user's granted folder holds.
class FolderEntry {
  const FolderEntry({
    required this.documentId,
    required this.name,
    required this.directory,
    required this.size,
  });

  /// The provider's handle for this file. Not a path: it only means anything
  /// passed back to the host alongside the granted tree.
  final String documentId;

  final String name;

  /// Folders between the picked root and this file, '' at the top.
  final String directory;

  final int size;
}

/// A folder the user picked, read through the Storage Access Framework.
///
/// Scoped storage will not let the app walk the folder a user keeps their DOS
/// games in, and
/// the permission that would - MANAGE_EXTERNAL_STORAGE - is one Play gates
/// behind a review aimed at file managers, backup and antivirus apps. An
/// undeclared one blocks the release outright. So the user grants one folder
/// through the system picker instead, and that grant persists across restarts.
///
/// What comes back is a document tree, not a path, and dosbox-x mounts a
/// DIRECTORY - `mount c <dir>` needs a real POSIX tree, so unlike a single
/// disk image there is nothing that can be materialised on demand. This is an
/// import source: the tree is enumerated with each entry's relative directory
/// intact, and [copyTo] writes the bytes into the app's own games folder,
/// which dosbox-x can then mount with no permission at all.
class MediaFolder {
  const MediaFolder._();

  static const MethodChannel _channel = MethodChannel('com.crownpark.retrodosbox/storage_permissions');

  /// Only Android needs this. iOS reads its own Documents folder directly, and
  /// a desktop has no scoped storage to work around.
  static bool get isSupported => Platform.isAndroid;

  /// The granted folder, or null if the user has not picked one.
  ///
  /// Asked of the system on every call rather than cached: a grant can be
  /// revoked in Settings, and carrying on with a dead URI looks exactly like
  /// the folder having been emptied.
  static Future<String?> granted() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('mediaFolderUri');
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> hasFolder() async => (await granted()) != null;

  /// The granted folder as something a person can recognise.
  ///
  /// A tree URI reads
  /// content://com.android.externalstorage.documents/tree/primary%3AAmiga,
  /// which tells the user nothing about whether they picked the right folder.
  /// The document id inside it is `primary:Amiga` for internal storage, or
  /// `[volume]:path` for an SD card, so it unpacks into something like
  /// /sdcard/Amiga. Falls back to the raw URI rather than guessing wrongly.
  static Future<String?> displayPath() async {
    final String? uri = await granted();
    return uri == null ? null : pathFromTreeUri(uri);
  }

  /// The readable path inside a tree URI. Pure, so it can be tested without a
  /// device: this is the part with the parsing bugs in it, not the channel.
  ///
  /// Anything unrecognised comes back as the URI it went in as. A wrong path
  /// shown confidently is worse than an ugly one, because the whole point of
  /// showing it is to let the user see they picked the wrong folder.
  @visibleForTesting
  static String pathFromTreeUri(String uri) {
    try {
      final int treeAt = uri.indexOf('/tree/');
      if (treeAt < 0) return uri;
      final String id = Uri.decodeComponent(uri.substring(treeAt + 6));
      final int colon = id.indexOf(':');
      if (colon < 0) return id;
      final String volume = id.substring(0, colon);
      final String path = id.substring(colon + 1);
      if (volume == 'primary') {
        return path.isEmpty ? '/sdcard' : '/sdcard/$path';
      }
      return path.isEmpty ? '/$volume' : '/$volume/$path';
    } on FormatException {
      return uri;
    }
  }

  /// Opens the system folder picker. Returns the granted folder, or null if
  /// the user backed out.
  static Future<String?> pick() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('pickMediaFolder');
    } on PlatformException {
      return null;
    }
  }

  static Future<void> forget() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('forgetMediaFolder');
    } on PlatformException {
      // Nothing granted: nothing to forget.
    }
  }

  /// Everything under the granted folder.
  ///
  /// [fileLimit] is a guard, not a preference: a user who points this at the
  /// top of their storage should get a long list, not an out-of-memory crash.
  static Future<List<FolderEntry>> list({int fileLimit = 20000}) async {
    if (!isSupported) return const <FolderEntry>[];
    try {
      final List<Object?>? raw = await _channel
          .invokeMethod<List<Object?>>('listMediaFolder', <String, Object>{
            'fileLimit': fileLimit,
          });
      if (raw == null) return const <FolderEntry>[];

      final List<FolderEntry> entries = <FolderEntry>[];
      for (final Object? item in raw) {
        if (item is! Map) continue;
        final String? id = item['documentId'] as String?;
        final String? name = item['name'] as String?;
        if (id == null || name == null) continue;
        entries.add(
          FolderEntry(
            documentId: id,
            name: name,
            directory: (item['directory'] as String?) ?? '',
            size: (item['size'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      return entries;
    } on PlatformException {
      return const <FolderEntry>[];
    }
  }

  /// Copies one entry into [destination], an ordinary path the core can open.
  static Future<bool> copyTo(FolderEntry entry, String destination) async {
    if (!isSupported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('copyFromMediaFolder', <String, Object>{
                'documentId': entry.documentId,
                'destination': destination,
              }) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}

/// Brings a granted folder's contents into the app's games folder.
///
/// dosbox-x mounts a directory, so a DOS title has to arrive whole: the .exe
/// next to its data files, in the same shape it had. Every entry's relative
/// directory is preserved for exactly that reason - flattening a collection
/// into one folder would produce something that lists fine and runs nothing.
///
/// Copies rather than moves. The folder belongs to the user, and a launcher
/// that empties somebody's collection because they pointed at it once is a
/// launcher that eats collections.
class MediaFolderImporter {
  const MediaFolderImporter._();

  /// Copies everything under the granted folder into [gamesFolder].
  ///
  /// [onProgress] reports (done, total) so a collection of thousands of small
  /// files shows something other than a frozen screen.
  static Future<int> importAll(
    String gamesFolder, {
    void Function(int done, int total)? onProgress,
  }) async {
    final entries = await MediaFolder.list();
    int copied = 0;

    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      onProgress?.call(i, entries.length);

      // The relative directory is what keeps a game a game.
      final destination = entry.directory.isEmpty
          ? '$gamesFolder/${entry.name}'
          : '$gamesFolder/${entry.directory}/${entry.name}';

      final existing = File(destination);
      // Same name and same length is the same file: re-copying a whole
      // collection on every import would be minutes of work to learn nothing.
      if (existing.existsSync() &&
          entry.size > 0 &&
          existing.lengthSync() == entry.size) {
        continue;
      }
      if (await MediaFolder.copyTo(entry, destination)) copied++;
    }
    onProgress?.call(entries.length, entries.length);
    return copied;
  }
}
