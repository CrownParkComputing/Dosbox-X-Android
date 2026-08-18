// Per-title settings, persisted separately from the library.
//
// Kept out of shared_preferences and out of the scan results deliberately:
// the library is derived data that gets thrown away and rebuilt on every
// rescan, whereas these are the user's own decisions about a title (which CPU
// preset it needs, whether it wants the Voodoo) and must survive that. The
// Java app made the same split, storing one JSON file per game under
// gamemeta/ -- this is that, keyed by GameEntry.slug.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/game_entry.dart';

class GameSettingsStore {
  GameSettingsStore._();
  static final GameSettingsStore instance = GameSettingsStore._();

  Directory? _dir;

  /// In-memory cache. The library grid asks for settings while building rows,
  /// so reading a file per card per frame is not viable.
  final Map<String, GameSettings> _cache = <String, GameSettings>{};

  Future<Directory> _settingsDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'gamesettings'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  File _fileFor(Directory dir, String slug) =>
      File(p.join(dir.path, '$slug.json'));

  /// Settings for [slug], or the defaults if none were ever saved.
  Future<GameSettings> load(String slug) async {
    final cached = _cache[slug];
    if (cached != null) return cached;

    final dir = await _settingsDir();
    final file = _fileFor(dir, slug);
    if (!file.existsSync()) {
      const defaults = GameSettings();
      _cache[slug] = defaults;
      return defaults;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final settings = decoded is Map<String, dynamic>
          ? GameSettings.fromJson(decoded)
          : const GameSettings();
      _cache[slug] = settings;
      return settings;
    } on FormatException {
      // A corrupt settings file must not make a title unlaunchable. Fall back
      // to defaults and let the next save overwrite it.
      const defaults = GameSettings();
      _cache[slug] = defaults;
      return defaults;
    } on FileSystemException {
      return const GameSettings();
    }
  }

  /// Cached settings without touching disk, or null if not loaded yet. For
  /// synchronous build methods that cannot await.
  GameSettings? peek(String slug) => _cache[slug];

  Future<void> save(String slug, GameSettings settings) async {
    _cache[slug] = settings;
    final dir = await _settingsDir();
    await _fileFor(dir, slug)
        .writeAsString(jsonEncode(settings.toJson()), flush: true);
  }

  /// Warms the cache for a whole library in one pass, so the grid can render
  /// per-title badges without a burst of async reads.
  Future<void> preload(Iterable<String> slugs) async {
    for (final slug in slugs) {
      if (!_cache.containsKey(slug)) await load(slug);
    }
  }
}
