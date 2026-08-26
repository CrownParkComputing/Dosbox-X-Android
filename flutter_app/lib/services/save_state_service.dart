// save_state_service.dart — Named save states with pictures, the family's
// States-tab model (Retro-Saturn's shape).
//
// The DIVISION OF LABOUR is the part worth understanding: the engine owns
// the state itself (DOSBox-X writes slot files under the title's own
// captures directory, so slots are per-title), and this service owns the
// USER'S RECORD of it -- which slot of which title was saved when, plus a
// thumbnail taken from the shared framebuffer. The engine may live in
// another process; the record always lives here.
//
// Slot 0 is reserved for the desktop pause snapshot; named saves rotate
// through slots 1..9 per title.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ffi/retrodosbox_bindings.dart' show FrameSnapshot;
import 'app_log.dart';

class SaveStateEntry {
  final String slug;
  final String title;

  /// The library path of the game, so the States tab can relaunch it even
  /// when the current scan has not listed it (folder unplugged, filter).
  final String gamePath;
  final int slot;
  final DateTime savedAt;
  final String? thumbnailPath;

  const SaveStateEntry({
    required this.slug,
    required this.title,
    required this.gamePath,
    required this.slot,
    required this.savedAt,
    this.thumbnailPath,
  });

  Map<String, Object?> toJson() => {
        'slug': slug,
        'title': title,
        'gamePath': gamePath,
        'slot': slot,
        'savedAt': savedAt.millisecondsSinceEpoch,
        'thumbnailPath': thumbnailPath,
      };

  static SaveStateEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final slug = raw['slug'];
    final title = raw['title'];
    final gamePath = raw['gamePath'];
    final slot = raw['slot'];
    final savedAt = raw['savedAt'];
    if (slug is! String ||
        title is! String ||
        gamePath is! String ||
        slot is! int ||
        savedAt is! int) {
      return null;
    }
    return SaveStateEntry(
      slug: slug,
      title: title,
      gamePath: gamePath,
      slot: slot,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt),
      thumbnailPath: raw['thumbnailPath'] as String?,
    );
  }

  /// "2 h ago" -- the human answer to "which one is that".
  String get ageDescription {
    final d = DateTime.now().difference(savedAt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

class SaveStateService {
  SaveStateService._();

  /// Named saves rotate 1..9; 0 belongs to the pause snapshot.
  static const int firstNamedSlot = 1;
  static const int slotCount = 10;

  static Directory? _dir;

  static Future<Directory> _stateDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'savestates'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  static Future<File> _indexFile() async =>
      File(p.join((await _stateDir()).path, 'index.json'));

  /// All recorded saves, newest first.
  static Future<List<SaveStateEntry>> list() async {
    try {
      final file = await _indexFile();
      if (!file.existsSync()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      final entries =
          decoded.map(SaveStateEntry.fromJson).whereType<SaveStateEntry>().toList();
      entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return entries;
    } catch (e) {
      AppLog.log('save-state index unreadable: $e');
      return const [];
    }
  }

  static Future<void> _write(List<SaveStateEntry> entries) async {
    final file = await _indexFile();
    await file.writeAsString(
        jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  /// Picks the slot a new save for [slug] should use: the least-recently
  /// used of 1..9, so nine saves per title survive before one is reused.
  static Future<int> nextSlotFor(String slug) async {
    final entries = await list();
    final used = <int, DateTime>{};
    for (final e in entries) {
      if (e.slug == slug) used[e.slot] = e.savedAt;
    }
    for (var s = firstNamedSlot; s < slotCount; s++) {
      if (!used.containsKey(s)) return s;
    }
    var oldest = firstNamedSlot;
    var oldestAt = DateTime.now();
    used.forEach((slot, at) {
      if (at.isBefore(oldestAt)) {
        oldest = slot;
        oldestAt = at;
      }
    });
    return oldest;
  }

  /// Records a save the engine has just been told to make, with a thumbnail
  /// from [frame] (the shared framebuffer, so this works across the
  /// process boundary too).
  static Future<void> record({
    required String slug,
    required String title,
    required String gamePath,
    required int slot,
    FrameSnapshot? frame,
  }) async {
    String? thumbPath;
    if (frame != null) {
      try {
        thumbPath = await _writeThumbnail(slug, slot, frame);
      } catch (e) {
        AppLog.log('save-state thumbnail failed: $e');
      }
    }
    final entries = (await list())
        .where((e) => !(e.slug == slug && e.slot == slot))
        .toList();
    entries.insert(
      0,
      SaveStateEntry(
        slug: slug,
        title: title,
        gamePath: gamePath,
        slot: slot,
        savedAt: DateTime.now(),
        thumbnailPath: thumbPath,
      ),
    );
    await _write(entries);
  }

  static Future<void> forget(SaveStateEntry entry) async {
    final entries = (await list())
        .where((e) => !(e.slug == entry.slug && e.slot == entry.slot))
        .toList();
    await _write(entries);
    final thumb = entry.thumbnailPath;
    if (thumb != null) {
      try {
        await File(thumb).delete();
      } catch (_) {
        // Already gone is fine.
      }
    }
  }

  static Future<String> _writeThumbnail(
      String slug, int slot, FrameSnapshot frame) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        frame.pixels.buffer
            .asUint8List(frame.pixels.offsetInBytes, frame.pixels.lengthInBytes));
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo info = await codec.getNextFrame();
    final ui.Image image = info.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (byteData == null) throw StateError('PNG encode failed');
    final dir = await _stateDir();
    final path = p.join(dir.path, '$slug-$slot.png');
    await File(path).writeAsBytes(byteData.buffer.asUint8List());
    return path;
  }
}
