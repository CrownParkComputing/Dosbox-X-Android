import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/conf_overrides.dart';
import 'data/dos_settings.dart';
import 'data/game_import.dart';
import 'emulator.dart';
import 'screens/advanced_config_screen.dart';
import 'screens/game_browser_screen.dart';
import 'screens/in_game_menu_screen.dart';

void main() => runApp(const DosboxLauncherApp());

class DosboxLauncherApp extends StatelessWidget {
  const DosboxLauncherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DOSBox-X',
      debugShowCheckedModeBanner: false,
      // The look every DOS user already knows: the deep blue of setup
      // programs and text-mode installers, amber where a cursor would glow.
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A2A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFB000),
          secondary: Color(0xFF55FFFF),
          surface: Color(0xFF10104A),
          surfaceContainerHighest: Color(0xFF1A1A5E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF10104A),
          foregroundColor: Color(0xFFFFB000),
        ),
        cardTheme: const CardThemeData(color: Color(0xFF10104A)),
      ),
      home: const ShelfScreen(),
    );
  }
}

/// The shelf, in two personalities.
///
/// Beginner mode is the app the Play Store already knows: your games, one
/// big way to add another, tap to play - the machine picks its own settings.
/// Geek mode adds the era picker on launch and the full 899-option
/// configuration surface. One switch in the menu moves between them; the
/// choice persists.
class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  static const MethodChannel _channel = MethodChannel('dosboxx/emulator');

  List<Directory> _games = const <Directory>[];
  String _gamesDir = '';
  String _filesDir = '';
  ConfOverrides _overrides = ConfOverrides.empty();
  /// Per-game settings, keyed by game folder path. A game's own settings are
  /// laid over the global ones at launch, so "this game runs slower" never
  /// means "every game runs slower".
  final Map<String, ConfOverrides> _perGame = <String, ConfOverrides>{};
  bool _geek = false;
  bool _busy = false;
  String _filter = '';
  Directory? _playing;

  List<Directory> get _shownGames => _filter.isEmpty
      ? _games
      : <Directory>[
          for (final Directory g in _games)
            if (g.path.split('/').last.toLowerCase().contains(_filter)) g,
        ];

  /// Settings this game carries of its own - shown on its row so tweaks are
  /// never invisible.
  int _gameTweakCount(Directory game) => _perGame[game.path]?.count ?? 0;

  Future<ConfOverrides> _gameOverrides(Directory game) async {
    final ConfOverrides? cached = _perGame[game.path];
    if (cached != null) return cached;
    final ConfOverrides loaded = await ConfOverrides.load(game.path);
    _perGame[game.path] = loaded;
    return loaded;
  }

  /// The per-game configuration screen: the same 899 options, saved into the
  /// game's own folder.
  Future<void> _editGameConfig(Directory game) async {
    final ConfOverrides o = await _gameOverrides(game);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AdvancedConfigScreen(
          overrides: o,
          onChanged: () {
            o.save(game.path);
            setState(() {});
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _load();
    // The emulator asks for our in-game menu through this channel; it is our
    // replacement for the DOSBox-X menu bar, which the core no longer draws.
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'showInGameMenu') await _showInGameMenu();
      return null;
    });
  }

  Future<void> _showInGameMenu() async {
    // The launcher may have been recycled while the game ran, in which case
    // the menu request arrives before _load() has read the mode and settings.
    if (_filesDir.isEmpty) await _load();
    if (!mounted) return;
    final Directory? game = _playing;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => InGameMenuScreen(
          geek: _geek,
          overrides: _overrides,
          filesDir: _filesDir,
          gameName: game?.path.split('/').last,
          onGameConfig: game == null ? null : () => _editGameConfig(game),
          onGlobalConfig: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (BuildContext context) => AdvancedConfigScreen(
                overrides: _overrides,
                onChanged: () {
                  if (_filesDir.isNotEmpty) _overrides.save(_filesDir);
                  setState(() {});
                },
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    _filesDir = await _channel.invokeMethod<String>('filesDir') ?? '';
    if (_filesDir.isNotEmpty) {
      _overrides = await ConfOverrides.load(_filesDir);
      _geek = File('$_filesDir/geek_mode').existsSync();
      final File last = File('$_filesDir/last_game');
      if (last.existsSync()) {
        final Directory d = Directory(last.readAsStringSync().trim());
        if (d.existsSync()) _playing = d;
      }
    }
    await _scan();
  }

  Future<void> _setGeek(bool on) async {
    setState(() => _geek = on);
    final File flag = File('$_filesDir/geek_mode');
    if (on) {
      flag.writeAsStringSync('');
    } else if (flag.existsSync()) {
      flag.deleteSync();
    }
  }

  Future<void> _scan() async {
    final String dir = await Emulator.gamesDir();
    final List<Directory> games = dir.isEmpty
        ? const <Directory>[]
        : (Directory(dir).listSync().whereType<Directory>().toList()
          ..sort((Directory a, Directory b) =>
              a.path.toLowerCase().compareTo(b.path.toLowerCase())));
    for (final Directory g in games) {
      _perGame[g.path] = await ConfOverrides.load(g.path);
    }
    if (mounted) {
      setState(() {
        _gamesDir = dir;
        _games = games;
      });
    }
  }

  Future<void> _addGame() async {
    // Zip or folder - both roads end at the same place: a folder on the
    // shelf and the which-program question answered up front.
    final String? kind = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('Browse the collection'),
              subtitle:
                  const Text('Search your whole game folder, A to Z'),
              onTap: () => Navigator.pop(context, 'browse'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip),
              title: const Text('A zip file'),
              subtitle: const Text('Downloaded game archives'),
              onTap: () => Navigator.pop(context, 'zip'),
            ),
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('A folder'),
              subtitle: const Text('A game already unpacked somewhere'),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
          ],
        ),
      ),
    );
    if (kind == null) return;

    if (kind == 'browse') {
      if (!mounted) return;
      final Directory? added = await Navigator.push<Directory>(
        context,
        MaterialPageRoute<Directory>(
          builder: (BuildContext context) =>
              GameBrowserScreen(gamesDir: _gamesDir),
        ),
      );
      if (added == null) return;
      await _scan();
      if (!mounted) return;
      await _chooseExe(added, announce: true);
      return;
    }

    setState(() => _busy = true);
    final Directory? added = kind == 'zip'
        ? await GameImport.pickAndImport(_gamesDir)
        : await GameImport.pickAndImportFolder(_gamesDir);
    setState(() => _busy = false);
    if (added == null) return;
    await _scan();
    if (!mounted) return;
    // The which-program question belongs to import, not to the first
    // bewildered tap later.
    await _chooseExe(added, announce: true);
  }

  /// Asks which program starts [game] and remembers the answer. With one
  /// obvious candidate it confirms silently.
  Future<void> _chooseExe(Directory game, {bool announce = false}) async {
    final List<String> candidates = GameImport.candidateExes(game);
    final String name = game.path.split('/').last;
    if (candidates.isEmpty) {
      if (announce && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$name is on the shelf - no programs found inside, '
              'it will open at the DOS prompt.'),
        ));
      }
      return;
    }
    final String? auto =
        GameImport.rememberedExe(game) ?? GameImport.autoExe(game);
    if (candidates.length == 1) {
      GameImport.rememberExe(game, candidates.first);
      if (announce && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$name is ready - runs ${candidates.first}.'),
        ));
      }
      return;
    }
    if (!mounted) return;
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text('$name - which program starts it?'),
        children: <Widget>[
          for (final String c in candidates.take(30))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c),
              child: Row(
                children: <Widget>[
                  Icon(
                    c == auto ? Icons.star : Icons.play_arrow,
                    size: 16,
                    color: c == auto
                        ? const Color(0xFFFFB000)
                        : const Color(0xFF55FFFF),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c,
                        style: const TextStyle(fontFamily: 'monospace')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) {
      GameImport.rememberExe(game, picked);
      if (announce && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name is ready - runs $picked.')),
        );
      }
    }
  }

  /// Long-press: everything about one game in one place.
  Future<void> _gameMenu(Directory game) async {
    final String name = game.path.split('/').last;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_geek)
              ListTile(
                leading: const Icon(Icons.tune, color: Color(0xFFFFB000)),
                title: const Text('Settings for this game'),
                subtitle: const Text('Only this game'),
                onTap: () => Navigator.pop(context, 'config'),
              ),
            ListTile(
              title: Text(name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  GameImport.rememberedExe(game) ?? 'no program chosen yet'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('Choose which program runs'),
              onTap: () => Navigator.pop(context, 'exe'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove from shelf'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'config') {
      await _editGameConfig(game);
      return;
    }
    if (action == 'exe') {
      await _chooseExe(game, announce: true);
    } else if (action == 'delete') {
      game.deleteSync(recursive: true);
      await _scan();
    }
  }

  Future<void> _play(Directory game) async {
    DosMachine machine = DosMachine.dx486;
    if (_geek) {
      // Geeks pick the era; beginners get a sensible 486.
      final DosMachine? chosen = await showDialog<DosMachine>(
        context: context,
        builder: (BuildContext context) => SimpleDialog(
          title: Text(game.path.split('/').last),
          children: <Widget>[
            for (final DosMachine m in DosMachine.all)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, m),
                child: Text(m.displayName),
              ),
          ],
        ),
      );
      if (chosen == null) return;
      machine = chosen;
    }
    // The remembered program, or the question now.
    String? exe = GameImport.rememberedExe(game);
    if (exe == null) {
      await _chooseExe(game);
      exe = GameImport.rememberedExe(game);
      if (exe == null && GameImport.candidateExes(game).isNotEmpty) {
        return; // asked and dismissed - not a launch
      }
    }

    // Mount the exe's own directory: DOS cannot speak the long folder names
    // a zip arrives with, and every game expects to run from where it lives.
    final String mount =
        exe == null ? game.path : File('${game.path}/$exe').parent.path;
    // Global settings first, then this game's own on top.
    final ConfOverrides forThisGame = ConfOverrides.layered(
        _overrides, await _gameOverrides(game));
    _playing = game;
    if (_filesDir.isNotEmpty) {
      File('$_filesDir/last_game').writeAsStringSync(game.path);
    }
    await Emulator.launch(
      DosSettings(
        machine: machine,
        mountPath: mount,
        autoexec: exe == null ? '' : exe.split('/').last,
      ),
      _geek ? forThisGame : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'DOSBox-X',
          style: TextStyle(fontFamily: 'monospace', letterSpacing: 2),
        ),
        actions: <Widget>[
          if (_geek)
            IconButton(
              tooltip: 'Configuration',
              icon: Badge(
                isLabelVisible: _overrides.count > 0,
                label: Text('${_overrides.count}'),
                child: const Icon(Icons.tune),
              ),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => AdvancedConfigScreen(
                    overrides: _overrides,
                    onChanged: () {
                      if (_filesDir.isNotEmpty) _overrides.save(_filesDir);
                      setState(() {});
                    },
                  ),
                ),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (String v) {
              if (v == 'mode') _setGeek(!_geek);
              if (v == 'rescan') _scan();
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: 'mode',
                checked: _geek,
                child: const Text('Geek mode'),
              ),
              const PopupMenuItem<String>(
                value: 'rescan',
                child: Text('Rescan shelf'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addGame,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add),
        label: const Text('Add a game'),
      ),
      body: _games.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.videogame_asset_off,
                      size: 56, color: Color(0xFF55FFFF)),
                  const SizedBox(height: 16),
                  const Text('No games yet.',
                      style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      'Tap "Add a game" and pick a zip - it lands on the '
                      'shelf ready to play.\n\nOr drop game folders into:\n'
                      '$_gamesDir',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6)),
                    ),
                  ),
                ],
              ),
            )
          : Column(
              children: <Widget>[
                if (_games.length > 6)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: TextField(
                      onChanged: (String v) =>
                          setState(() => _filter = v.toLowerCase()),
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon:
                            const Icon(Icons.search, color: Color(0xFF55FFFF)),
                        hintText: 'Search ${_games.length} games...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: _shownGames.length,
                    separatorBuilder: (BuildContext c, int i) =>
                        const Divider(height: 1, color: Color(0x22FFFFFF)),
                    itemBuilder: (BuildContext context, int i) {
                      final Directory game = _shownGames[i];
                      final String name = game.path.split('/').last;
                      final int tweaks = _gameTweakCount(game);
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.play_circle_outline,
                            color: Color(0xFFFFB000)),
                        title: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 14),
                        ),
                        subtitle: tweaks == 0
                            ? null
                            : Text('$tweaks setting${tweaks == 1 ? '' : 's'} '
                                'for this game',
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xFF55FFFF))),
                        trailing: IconButton(
                          tooltip: 'This game',
                          icon: const Icon(Icons.more_vert, size: 20),
                          onPressed: () => _gameMenu(game),
                        ),
                        onTap: () => _play(game),
                        onLongPress: () => _gameMenu(game),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
