import 'dart:io';

import 'package:flutter/services.dart';

import 'game_import.dart';

/// One entry in the user's game collection folder.
class SourceEntry {
  const SourceEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.isDir,
  });

  final String id;
  final String name;
  final int size;
  final bool isDir;

  /// The letter this entry files under in the A-Z strip: A-Z, or '#'
  /// for anything starting with a digit or symbol.
  String get letter {
    if (name.isEmpty) return '#';
    final String c = name[0].toUpperCase();
    return RegExp(r'[A-Z]').hasMatch(c) ? c : '#';
  }
}

/// The set folder holding the user's whole DOS collection - thousands of
/// zips browsed inside the app, never through a system picker. Backed by a
/// persisted SAF tree grant, same approach the Java launcher shipped with.
class SourceCollection {
  static const MethodChannel _channel = MethodChannel('dosboxx/emulator');

  /// The chosen folder's display name, or null when none is set yet.
  static Future<String?> folderName() async {
    final Map<Object?, Object?>? info =
        await _channel.invokeMethod<Map<Object?, Object?>>('sourceFolder');
    return info?['name'] as String?;
  }

  /// Opens the system tree picker once; the grant persists across restarts.
  /// Returns the folder's display name, or null if the user backed out.
  static Future<String?> pickFolder() async {
    final Map<Object?, Object?>? info =
        await _channel.invokeMethod<Map<Object?, Object?>>('pickSourceFolder');
    return info?['name'] as String?;
  }

  /// Every zip in the collection folder, sorted by name. Folders and other
  /// file types are left out: the collection browser is for game archives.
  static Future<List<SourceEntry>> list() async {
    final List<Object?>? raw =
        await _channel.invokeMethod<List<Object?>>('listSource');
    if (raw == null) return <SourceEntry>[];
    final List<SourceEntry> out = <SourceEntry>[];
    for (final Object? e in raw) {
      final Map<Object?, Object?> m = e! as Map<Object?, Object?>;
      final SourceEntry entry = SourceEntry(
        id: m['id']! as String,
        name: m['name']! as String,
        size: (m['size'] as num?)?.toInt() ?? 0,
        isDir: m['dir'] == true,
      );
      if (!entry.isDir && entry.name.toLowerCase().endsWith('.zip')) {
        out.add(entry);
      }
    }
    out.sort((SourceEntry a, SourceEntry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Copies [entry] out of the SAF tree and imports it onto the shelf.
  /// Returns the new game folder, or null if anything failed. The temp copy
  /// never outlives the call.
  static Future<Directory?> import(SourceEntry entry, String gamesDir) async {
    final String? tmp = await _channel.invokeMethod<String>(
        'importFromSource',
        <String, String>{'id': entry.id, 'name': entry.name});
    if (tmp == null) return null;
    final File file = File(tmp);
    try {
      return GameImport.importZip(file, gamesDir);
    } finally {
      if (file.existsSync()) file.deleteSync();
    }
  }
}
