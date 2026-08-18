// The app shell: sidebar plus content panel, and the owner of the session.
//
// This screen holds the things that outlive any one tab -- the core, the
// scanned library, the gamepad service, and which title is running. Tabs are
// swapped in the content panel rather than pushed as routes, which is what
// keeps a running session alive while the user goes to change a setting.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/game_entry.dart';
import '../ffi/dosbox_core.dart';
import '../ffi/dosbox_native_paths.dart';
import '../services/app_restart_service.dart';
import '../services/dos_conf_builder.dart';
import '../services/game_settings_store.dart';
import '../services/games_folder.dart';
import 'package:file_picker/file_picker.dart';

import '../services/game_importer.dart';
import '../services/zip_runner.dart';
import '../services/gamepad_service.dart';
import '../services/library_scanner.dart';
import '../theme/dosbox_theme.dart';
import '../widgets/sidebar.dart';
import 'about_screen.dart';
import 'dos_config_screen.dart';
import 'emulator_screen.dart';
import 'input_settings_screen.dart';
import 'library_grid.dart';
import 'paths_settings_screen.dart';
import 'video_settings_screen.dart';

enum WorkbenchTab {
  games('Games'),
  running('Running'),
  video('Video'),
  input('Input'),
  engine('Engine'),
  paths('Paths'),
  about('About');

  final String title;
  const WorkbenchTab(this.title);
}

class WorkbenchScreen extends StatefulWidget {
  final DosboxCore core;
  final VoidCallback onRunSetupWizard;

  const WorkbenchScreen({
    super.key,
    required this.core,
    required this.onRunSetupWizard,
  });

  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends State<WorkbenchScreen>
    with WidgetsBindingObserver {
  WorkbenchTab _tab = WorkbenchTab.games;

  List<GameEntry> _entries = const <GameEntry>[];
  List<String> _unreadable = const <String>[];
  bool _scanning = false;

  GameEntry? _session;
  String? _launchError;

  /// The cache setup of the running archive session, if any. Held here so
  /// the next launch can replay save files from cacheRoot into saveRoot.
  ArchiveRunSetup? _pendingArchiveSetup;

  final GamepadService _gamepads = GamepadService();
  StreamSubscription<int>? _gamepadSub;
  bool _controllerConnected = false;

  @override
  void initState() {
    super.initState();
    _rescan();
    _startGamepads();
  }

  void _startGamepads() {
    _gamepads.start();
    _gamepadSub = _gamepads.maskChanges.listen((mask) {
      // Forwarded straight through: an external pad is the emulated PC
      // joystick, with no on-screen state to merge.
      widget.core.joystick(0, mask);
    });
    // The service polls for connection changes rather than exposing a one-shot
    // value, so the shell has to follow it: the Input screen and the
    // on-screen-pad `auto` mode both depend on the live answer.
    _gamepads.connected.addListener(_onControllerChanged);
    _controllerConnected = _gamepads.connected.value;
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() => _controllerConnected = _gamepads.connected.value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the app is backgrounded, the dosbox-x process is paused but its
    // writes to the cached C: drive are still in cacheRoot. Replay the
    // user's changes from cacheRoot into saveRoot so they survive a kill
    // -- the system may reclaim the app while it is in the background.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final setup = _pendingArchiveSetup;
      if (setup != null) {
        // Fire and forget: the lifecycle callback is synchronous, and we
        // cannot await I/O here without stalling the framework.
        () async {
          await ZipRunner.persistSaves(
            cacheRoot: setup.cacheRoot,
            saveRoot: setup.saveRoot,
          );
        }();
      }
    }
  }

  @override
  void dispose() {
    // Best-effort save persistence on the way out. The user has stopped
    // using the app, so this is the last clean opportunity to flush.
    final setup = _pendingArchiveSetup;
    if (setup != null) {
      // Async, but dispose() does not await. Errors are logged in the
      // service layer if they happen; there is no recovery to perform
      // here.
      () async {
        await ZipRunner.persistSaves(
          cacheRoot: setup.cacheRoot,
          saveRoot: setup.saveRoot,
        );
      }();
    }
    _gamepadSub?.cancel();
    _gamepads.connected.removeListener(_onControllerChanged);
    _gamepads.dispose();
    super.dispose();
  }

  Future<void> _rescan() async {
    // GamesFolder.resolve() never returns null: it falls back to the default
    // Retro-DosBox folder and creates it. On iOS that folder existing is what
    // makes the app appear in Files at all, so there is nowhere to drop a game
    // until something has made it.
    final folder = await GamesFolder.resolve();

    setState(() => _scanning = true);

    // Archives are now run in place via ZipRunner; the scanner picks them up
    // directly. We no longer auto-import zips on every rescan: doing so on a
    // 3,000-title collection requires reading each zip, which takes many
    // seconds and is destructive (the originals get deleted on success).
    // Users who DO want a zip unpacked into the games folder use the
    // "Add game" button, which calls ZipImporter for one file at a time.
    await Future.value();

    final result = await LibraryScanner.scan(folder);
    await GameSettingsStore.instance.preload(result.entries.map((e) => e.slug));
    if (!mounted) return;
    setState(() {
      _entries = result.entries;
      _unreadable = result.unreadable;
      _scanning = false;
    });
  }

  /// Imports a single zip or folder from the system file picker into the
  /// games folder, then rescans so the new title appears.
  ///
  /// The picker is offered in two flavours in one dialog: tapping the
  /// "Pick a folder" entry opens the directory picker for a folder of
  /// .exe/.com/.bat files (an installed DOS game), and tapping "Pick a zip"
  /// opens the file picker for a zip archive.
  Future<void> _addGame() async {
    final folder = await GamesFolder.resolve();
    if (!mounted) return;

    // Show a small chooser. file_picker does not expose a single dialog
    // that picks both files and folders, so we ask the user which one they
    // want via a modal bottom sheet, then delegate to the right call.
    final choice = await showModalBottomSheet<_AddGameChoice>(
      context: context,
      backgroundColor: DosColors.rootBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder, color: DosColors.textMuted2),
              title: const Text(
                'Pick a folder',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: const Text(
                'A folder of EXE/COM/BAT files -- an installed DOS game',
                style: DosTextStyles.statusLine,
              ),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_AddGameChoice.folder),
            ),
            ListTile(
              leading: const Icon(Icons.archive, color: DosColors.textMuted2),
              title: const Text(
                'Pick a zip',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: const Text(
                'A zip archive -- will be unpacked into the games folder',
                style: DosTextStyles.statusLine,
              ),
              onTap: () => Navigator.of(sheetContext).pop(_AddGameChoice.zip),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    String? sourcePath;
    if (choice == _AddGameChoice.folder) {
      sourcePath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Pick a game folder',
      );
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result != null && result.files.isNotEmpty) {
        sourcePath = result.files.first.path;
      }
    }
    if (sourcePath == null || !mounted) return;

    setState(() => _scanning = true);
    final imported = await GameImporter.importOne(sourcePath, folder);
    if (!mounted) return;
    setState(() => _scanning = false);

    if (imported == null) {
      setState(
        () => _launchError =
            'Could not import $sourcePath. The file or folder may be unreadable, or the games folder is on a different volume.',
      );
    } else {
      await _rescan();
    }
  }

  Future<void> _launch(GameEntry entry, {String? launcher}) async {
    final settings = await GameSettingsStore.instance.load(entry.slug);

    // Archives get extracted into a per-title cache before conf building,
    // because the conf has to mount a real directory as C: and the zip is
    // opaque to dosbox-x. The setup is held until the session ends so the
    // user's saves can be replayed from cacheRoot to saveRoot on next launch.
    ArchiveRunSetup? archiveSetup;
    if (entry.kind == GameKind.archive) {
      setState(() => _scanning = true);
      archiveSetup = await ZipRunner.prepare(
        zip: File(entry.path),
        slug: entry.slug,
      );
      if (!mounted) {
        setState(() => _scanning = false);
        return;
      }
      setState(() => _scanning = false);
      if (archiveSetup == null) {
        setState(
          () => _launchError =
              'Could not read ${entry.title}.zip -- the archive may be corrupt.',
        );
        return;
      }
    }

    final conf = DosConfBuilder.build(
      entry: entry,
      settings: settings,
      launcher: launcher,
      archiveSetup: archiveSetup,
    );

    // One conf file per title rather than a single shared one, so a crashed
    // session cannot leave behind a config that silently changes the next
    // launch.
    final dir = await DosboxNativePaths.confDir();
    final file = File('${dir.path}/${entry.slug}.conf');
    await file.writeAsString(conf, flush: true);

    final result = widget.core.start(file.path);
    if (!mounted) return;

    if (result == DosboxResult.alreadyStarted) {
      // Honest about the real constraint: DOSBox-X has no working teardown, so
      // one session per app launch is all the core can currently deliver.
      // Saying so beats appearing to ignore the tap.
      setState(
        () => _launchError =
            'A session is already running. Because DOSBox-X cannot be shut '
            'down and restarted in-process, launching another title needs the '
            'app to be restarted.',
      );
      return;
    }
    if (result != DosboxResult.ok) {
      setState(() => _launchError = 'Failed to start ${entry.title}.');
      return;
    }
    setState(() {
      _session = entry;
      _pendingArchiveSetup = archiveSetup;
      _launchError = null;
      _tab = WorkbenchTab.running;
    });
  }

  /// Closes the running session. DOSBox-X cannot safely tear down and restart
  /// in-process, so Android relaunches the app into a fresh process. That makes
  /// the close button honest: after it returns to the library, another title
  /// can be launched immediately.
  Future<void> _onSessionExit() async {
    final setup = _pendingArchiveSetup;
    if (setup != null) {
      await ZipRunner.persistSaves(
        cacheRoot: setup.cacheRoot,
        saveRoot: setup.saveRoot,
      );
    }

    if (await AppRestartService.restart()) return;
    if (!mounted) return;

    // Desktop/iOS fallback. A future core with complete teardown can return
    // ok here and use the same UI path without needing an app restart.
    final result = widget.core.stop();
    if (result == DosboxResult.ok) {
      setState(() {
        _session = null;
        _pendingArchiveSetup = null;
        _tab = WorkbenchTab.games;
      });
    } else {
      setState(() {
        _tab = WorkbenchTab.games;
        _launchError =
            'This platform cannot restart DOSBox-X in-process. '
            'Close and reopen the app before launching another title.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    return Container(
      color: DosColors.rootBackground,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(DosMetrics.rootPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: DosMetrics.sidebarMaxWidth(screenWidth),
                ),
                child: Sidebar(
                  destinations: [
                    for (final tab in WorkbenchTab.values)
                      SidebarDestination(tab.title),
                  ],
                  selectedIndex: _tab.index,
                  onSelected: (i) =>
                      setState(() => _tab = WorkbenchTab.values[i]),
                  footer: _sidebarFooter(),
                ),
              ),
              const SizedBox(width: DosMetrics.contentLeftMargin),
              Expanded(child: _contentPanel()),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _sidebarFooter() {
    final session = _session;
    if (session == null) return null;
    return Text(
      widget.core.isPaused ? 'PAUSED\n${session.title}' : session.title,
      style: DosTextStyles.statusLine,
    );
  }

  Widget _contentPanel() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DosColors.panelFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DosColors.panelStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_launchError != null) _errorBanner(_launchError!),
          Expanded(child: _tabContent()),
        ],
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DosColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: DosColors.warning),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: DosColors.warning, fontSize: 12),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _launchError = null),
            icon: const Icon(Icons.close, size: 16),
            color: DosColors.warning,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _tabContent() {
    switch (_tab) {
      case WorkbenchTab.games:
        if (_scanning) return const Center(child: CircularProgressIndicator());
        return LibraryGrid(
          entries: _entries,
          unreadable: _unreadable,
          onLaunch: _launch,
          onShowDetails: _showDetails,
          onRescan: _rescan,
          onAddGame: _addGame,
        );
      case WorkbenchTab.running:
        final session = _session;
        if (session == null) {
          return const Center(
            child: Text(
              'No session running. Pick a title from Games.',
              style: TextStyle(color: DosColors.textMuted),
            ),
          );
        }
        return EmulatorScreen(
          core: widget.core,
          title: session.title,
          controllerConnected: _controllerConnected,
          onExit: () => unawaited(_onSessionExit()),
        );
      case WorkbenchTab.video:
        return const VideoSettingsScreen();
      case WorkbenchTab.input:
        return InputSettingsScreen(
          core: widget.core,
          controllerConnected: _controllerConnected,
        );
      case WorkbenchTab.engine:
        return DosConfigScreen(core: widget.core);
      case WorkbenchTab.paths:
        return PathsSettingsScreen(
          onGamesFolderChanged: _rescan,
          onRunSetupWizard: widget.onRunSetupWizard,
        );
      case WorkbenchTab.about:
        return const AboutScreen();
    }
  }

  /// Per-title settings and program picker.
  void _showDetails(GameEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: DosColors.cardFill,
      isScrollControlled: true,
      builder: (context) => _GameDetailsSheet(
        entry: entry,
        onLaunch: (launcher) {
          Navigator.of(context).pop();
          _launch(entry, launcher: launcher);
        },
      ),
    );
  }
}

/// Per-title sheet: which program to run, and the settings that change how the
/// machine is configured for it.
class _GameDetailsSheet extends StatefulWidget {
  final GameEntry entry;
  final void Function(String? launcher) onLaunch;

  const _GameDetailsSheet({required this.entry, required this.onLaunch});

  @override
  State<_GameDetailsSheet> createState() => _GameDetailsSheetState();
}

class _GameDetailsSheetState extends State<_GameDetailsSheet> {
  GameSettings _settings = const GameSettings();

  @override
  void initState() {
    super.initState();
    GameSettingsStore.instance.load(widget.entry.slug).then((s) {
      if (mounted) setState(() => _settings = s);
    });
  }

  Future<void> _update(GameSettings next) async {
    setState(() => _settings = next);
    await GameSettingsStore.instance.save(widget.entry.slug, next);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              entry.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Hardware generation',
              style: TextStyle(color: DosColors.textMuted2, fontSize: 12),
            ),
            const SizedBox(height: 6),
            // Presets rather than a raw cycles field: "which era is this game
            // from" is a question a user can answer, whereas "how many cycles
            // per millisecond" is not.
            RadioGroup<CpuPreset>(
              groupValue: _settings.preset,
              onChanged: (v) =>
                  v == null ? null : _update(_settings.copyWith(preset: v)),
              child: Column(
                children: [
                  for (final preset in CpuPreset.values)
                    RadioListTile<CpuPreset>(
                      value: preset,
                      dense: true,
                      title: Text(
                        preset.label,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              value: _settings.voodoo,
              onChanged: (v) => _update(_settings.copyWith(voodoo: v)),
              dense: true,
              title: const Text(
                '3dfx Voodoo',
                style: TextStyle(fontSize: 13, color: Colors.white),
              ),
              subtitle: const Text(
                'Software rasterizer. Costs a lot of CPU; only a few titles '
                'use it.',
                style: TextStyle(fontSize: 11, color: DosColors.textMuted),
              ),
            ),
            SwitchListTile(
              value: _settings.joystick,
              onChanged: (v) => _update(_settings.copyWith(joystick: v)),
              dense: true,
              title: const Text(
                'Emulated joystick',
                style: TextStyle(fontSize: 13, color: Colors.white),
              ),
            ),
            const SizedBox(height: 12),
            if (entry.launchers.length > 1) ...[
              const Text(
                'Program to run',
                style: TextStyle(color: DosColors.textMuted2, fontSize: 12),
              ),
              const SizedBox(height: 6),
              for (final launcher in entry.launchers)
                ListTile(
                  dense: true,
                  title: Text(
                    launcher.split(RegExp(r'[/\\]')).last,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                  ),
                  trailing: const Icon(Icons.play_arrow, size: 18),
                  onTap: () => widget.onLaunch(launcher),
                ),
            ],
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => widget.onLaunch(null),
              child: const Text('Play'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _AddGameChoice { folder, zip }
