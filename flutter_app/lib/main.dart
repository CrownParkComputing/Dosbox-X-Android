import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'data/conf_overrides.dart';
import 'data/dos_settings.dart';
import 'emulator.dart';
import 'screens/advanced_config_screen.dart';

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

/// The game shelf: every subfolder of games/ is a game, tap to set up and
/// play. The same shape as the Amiga launcher's library, DOS-flavoured.
class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  List<Directory> _games = const <Directory>[];
  String _gamesDir = '';
  ConfOverrides _overrides = ConfOverrides.empty();
  String _filesDir = '';

  @override
  void initState() {
    super.initState();
    _scan();
    _loadOverrides();
  }

  Future<void> _loadOverrides() async {
    _filesDir = await const MethodChannel('dosboxx/emulator')
            .invokeMethod<String>('filesDir') ??
        '';
    if (_filesDir.isNotEmpty) {
      _overrides = await ConfOverrides.load(_filesDir);
      if (mounted) setState(() {});
    }
  }

  Future<void> _scan() async {
    final String dir = await Emulator.gamesDir();
    final List<Directory> games = dir.isEmpty
        ? const <Directory>[]
        : Directory(dir)
            .listSync()
            .whereType<Directory>()
            .toList()
      ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    if (mounted) {
      setState(() {
        _gamesDir = dir;
        _games = games;
      });
    }
  }

  Future<void> _play(Directory game) async {
    // The wizard, sized to what a first slice needs: pick the machine, go.
    // The exe hunt and per-game remembered settings come with the library
    // layer; a mounted C: and a DIR prompt already proves the whole chain.
    final DosMachine? machine = await showDialog<DosMachine>(
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
    if (machine == null) return;
    await Emulator.launch(
      DosSettings(machine: machine, mountPath: game.path),
      _overrides,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DOSBox-X'),
        actions: <Widget>[
          IconButton(onPressed: _scan, icon: const Icon(Icons.refresh)),
          // The complex GUI: every section and option the core knows.
          IconButton(
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
        ],
      ),
      body: _games.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No games yet.\n\nPut each game in its own folder under:\n'
                  '$_gamesDir\n\nthen pull to refresh.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: _games.length,
              itemBuilder: (BuildContext context, int i) {
                final Directory game = _games[i];
                return ListTile(
                  leading: const Icon(Icons.videogame_asset),
                  title: Text(game.path.split('/').last),
                  onTap: () => _play(game),
                );
              },
            ),
    );
  }
}
