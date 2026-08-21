// The app shell: sidebar plus content panel, and the owner of the session.
//
// This screen holds the things that outlive any one tab -- the core, the
// scanned library, the gamepad service, and which title is running. Tabs are
// swapped in the content panel rather than pushed as routes, which is what
// keeps a running session alive while the user goes to change a setting.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/game_entry.dart';
import '../ffi/retrodosbox_core.dart';
import '../ffi/retrodosbox_native_paths.dart';
import '../services/app_prefs.dart';
import '../services/app_restart_service.dart';
import '../services/retrodosbox_conf_builder.dart';
import '../services/game_settings_store.dart';
import '../services/games_folder.dart';
import 'package:file_picker/file_picker.dart';

import '../services/game_importer.dart';
import '../services/media_folder.dart';
import '../services/zip_runner.dart';
import '../services/emulator_input.dart';
import '../services/gamepad_service.dart';
import '../services/library_scanner.dart';
import '../theme/retrodosbox_theme.dart';
import '../data/emulator_ui_state.dart';
import '../widgets/emulator_control_strip.dart';
import '../widgets/sidebar.dart';
import '../widgets/sidebar_style.dart';
import 'about_screen.dart';
import 'retrodosbox_config_screen.dart';
import 'emulator_screen.dart';
import 'input_settings_screen.dart';
import 'library_grid.dart';
import 'paths_settings_screen.dart';
import 'video_settings_screen.dart';

/// The side-nav destinations. Icons and titles use the same vocabulary as the
/// sibling front ends (Retro-C64's WorkbenchCategory), so the rail reads the
/// same across the family even where the tab set differs by machine -- DOS
/// has an Engine tab and no Music tab, and that is the only difference a user
/// should notice.
enum WorkbenchTab {
  // The same rail shape as the Amiga and C64 front ends, so the family reads
  // as one: what you play at the top, how the machine is set up in the middle,
  // the reference-y things at the bottom. The groups are what the rail draws
  // its hairlines between; About is pinned to the far end the way it always is.
  games('\u{1F3AE}', 'Games', 0),
  running('\u{25B6}\u{FE0F}', 'Running', 0),
  video('\u{1F4FA}', 'Video', 1),
  input('\u{1F579}\u{FE0F}', 'Input', 1),
  engine('\u{2699}\u{FE0F}', 'Engine', 1),
  paths('\u{1F4C2}', 'Paths', 1),
  about('\u{2139}\u{FE0F}', 'About', 2);

  final String icon;
  final String title;

  /// Which band of the rail this sits in. See the Sidebar's group handling.
  final int group;

  const WorkbenchTab(this.icon, this.title, this.group);
}

class WorkbenchScreen extends StatefulWidget {
  final RetroDosboxCore core;
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

  /// Title of a session that has been snapshotted via Pause. Distinct from
  /// [_session] so the X-on-emulator kill path and the Pause-and-return
  /// path don't fight over the same field. The core is paused but still
  /// running in the background (DOSBox-X's save slots are in-process, so
  /// tearing it down would discard the snapshot), which is why this can
  /// coexist with no [_session] while still blocking a fresh launch.
  GameEntry? _pausedSession;

  /// The cache setup of the running archive session, if any. Held here so
  /// the next launch can replay save files from cacheRoot into saveRoot.
  ArchiveRunSetup? _pendingArchiveSetup;

  final GamepadService _gamepads = GamepadService();

  /// Whether the in-game chrome is on screen. It hides itself a few seconds
  /// after the last touch, because a DOS game is 4:3 on a widescreen handheld
  /// and every pixel of chrome is a pixel of picture.
  bool _chromeVisible = true;
  Timer? _chromeTimer;

  /// Whether the system bars are currently hidden. Tracked so the mode is set
  /// once on each transition rather than on every rebuild.
  bool _immersive = false;

  /// Where input goes: the core here on desktop, the :dosbox process on
  /// Android. See EmulatorInput.
  late final EmulatorInput _input =
      EmulatorInput.forSession(core: widget.core);
  StreamSubscription<JoystickState>? _gamepadSub;
  bool _controllerConnected = false;
  bool _sidebarHidden = false;

  /// Keyboard and trackpad-mouse state. Owned here rather than in the
  /// emulator screen because the buttons that toggle them are on the status
  /// row below the picture, in a different subtree.
  final EmulatorUiState _emulatorUi = EmulatorUiState();

  @override
  void initState() {
    super.initState();
    // The scan first, then anything the last process asked us to launch: the
    // entry has to exist in _library before it can be found by slug.
    _rescan().then((_) => _resumePendingLaunch());
    _startGamepads();
    AppPrefs.getSidebarHidden().then((hidden) {
      if (mounted) setState(() => _sidebarHidden = hidden);
    });
  }

  void _startGamepads() {
    _gamepads.start();
    _gamepadSub = _gamepads.stateChanges.listen((state) {
      // Forwarded straight through: an external pad is the emulated PC
      // joystick, with no on-screen state to merge. Both halves matter:
      // digital DOS games read the mask via BIOS int 15h, but analog-era
      // titles (Uridium, flight sims) read the X/Y axes. Passing only the
      // mask is what made Uridium require constant re-tapping -- the game
      // saw the press once, but never a held position.
      _input.joystick(0, state.mask, axisX: state.axisX, axisY: state.axisY);
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
    _chromeTimer?.cancel();
    // The library is not a fullscreen game, and leaving the bars hidden would
    // outlive this screen.
    if (_immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  /// Attaches to the emulator process's frame mapping once it exists.
  ///
  /// Bounded: a mapping that never appears means the other process failed to
  /// start, and retrying forever would just hide that.
  Future<void> _attachWhenReady(String path) async {
    for (var i = 0; i < 100; i++) { // 100 x 100ms = 10s
      if (!mounted || _session == null) return;
      // Retry until the attach SUCCEEDS, not until the file appears.
      //
      // The writer creates the file and only then sizes it, so there is a
      // window where it exists at zero length. An attach in that window is
      // refused - correctly, the header is not there yet - and giving up on
      // the first failure left the panel black while the game ran perfectly
      // with sound, which is exactly how it presented.
      if (File(path).existsSync() &&
          widget.core.attachSharedFrameIfPossible(path)) {
        // Kept: an attach that takes suspiciously long, or never happens, is
        // the difference between a black panel and a working one, and it is
        // not visible from anywhere else.
        debugPrint('dosbox: attached shared frame after ${i * 100}ms');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    setState(
      () => _launchError =
          'The emulator process did not start. Try again, or restart the app.',
    );
  }

  /// Launches whatever was chosen before the process was replaced.
  ///
  /// Switching games restarts the app - DOSBox-X cannot start twice in one
  /// process - so the choice is parked in prefs and picked up here, once the
  /// library has been scanned and the entry can be found again.
  Future<void> _resumePendingLaunch() async {
    final slug = await AppPrefs.takePendingLaunch();
    if (slug == null || !mounted) return;
    GameEntry? entry;
    for (final e in _entries) {
      if (e.slug == slug) {
        entry = e;
        break;
      }
    }
    // A title that has since been deleted or renamed simply does not launch;
    // the pending choice is already cleared, so it cannot haunt the next run.
    if (entry == null || !mounted) return;
    await _launch(entry);
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
      backgroundColor: RetroDosboxColors.rootBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder, color: RetroDosboxColors.textMuted2),
              title: const Text(
                'Pick a folder',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: const Text(
                'A folder of EXE/COM/BAT files -- an installed DOS game',
                style: RetroDosboxTextStyles.statusLine,
              ),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_AddGameChoice.folder),
            ),
            ListTile(
              leading: const Icon(Icons.archive, color: RetroDosboxColors.textMuted2),
              title: const Text(
                'Pick a zip',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: const Text(
                'A zip archive -- will be unpacked into the games folder',
                style: RetroDosboxTextStyles.statusLine,
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
      // Android goes through SAF and copies the tree in itself.
      //
      // getDirectoryPath returns a path dart:io cannot read on Android 11+
      // without all-files access, which this app no longer asks for. The
      // import has to happen through the document tree, and it lands directly
      // in the games folder rather than being copied twice.
      if (Platform.isAndroid) {
        final granted = await MediaFolder.pick();
        if (granted == null || !mounted) return;
        setState(() => _scanning = true);
        final copied = await MediaFolderImporter.importAll(folder);
        if (!mounted) return;
        setState(() => _scanning = false);
        await _rescan();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(copied == 0
                ? 'Nothing new found in that folder.'
                : 'Imported $copied file${copied == 1 ? '' : 's'}.'),
          ));
        }
        return;
      }
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

    final captureRoot = await RetroDosboxNativePaths.captureRoot();
    final conf = RetroDosboxConfBuilder.build(
      entry: entry,
      settings: settings,
      launcher: launcher,
      archiveSetup: archiveSetup,
      captureRoot: captureRoot.path,
      // Always offscreen. The engine has no window of its own any more, in
      // either process: it publishes finished frames through the gamelink
      // output the bridge hooks, and whoever is drawing - this process or
      // another one - reads them from there.
      windowed: false,
    );

    // One conf file per title rather than a single shared one, so a crashed
    // session cannot leave behind a config that silently changes the next
    // launch.
    final dir = await RetroDosboxNativePaths.confDir();
    final file = File('${dir.path}/${entry.slug}.conf');
    await file.writeAsString(conf, flush: true);

    // Try to start; if a session is in the way, snapshot it, take it down and
    // try once more.
    //
    // Asking first was the obvious shape and it does not work. The core keeps
    // two flags: g_running, true only while the engine mainloop is executing,
    // and g_started, true from start() until teardown. isRunning reports
    // g_running, but start() refuses on g_started - so during startup, or
    // after the mainloop has returned, the two disagree and a guard on
    // isRunning skips the teardown while start() still says "already
    // started". Letting the core answer removes the guesswork: it is the only
    // thing that knows its own state.
    //
    // The snapshot survives the teardown because DOSBox-X writes save states
    // to disk - `<captures>/../save/<slot>.sav` - rather than holding them in
    // the running core, and each title now has its own captures directory, so
    // slot 0 is that title's slot rather than a shared one.
    // Android runs the core in its own process: a session is a process, so it
    // ends by ending, and the next game gets a fresh engine without this
    // launcher going anywhere. Everything the one-shot core problem used to
    // cost - the wedged engine, the app restart - goes with it.
    if (EmulatorProcess.isSupported) {
      // One mapping, reused: the emulator process publishes into it and this
      // one draws from it. In the app's own support directory rather than the
      // cache, because a mapping the system may delete underneath a running
      // engine is a picture that stops for no visible reason.
      final shared =
          '${(await RetroDosboxNativePaths.captureRoot()).path}/frame.shm';

      // Start from nothing, every time.
      //
      // The mapping outlives the process that made it, so a stale one from the
      // last session is still on disk - and attaching to THAT succeeds
      // instantly, against a file the new engine has not touched yet. The
      // panel then polls a counter that never moves, which reads as a game
      // that renders nothing while running perfectly. Deleting it first makes
      // "the file exists" mean "this session's engine created it".
      final staleFrame = File(shared);
      if (staleFrame.existsSync()) staleFrame.deleteSync();

      // And the previous engine has to be gone before a new one starts: the
      // core is one-shot, so a second start in a surviving process is refused
      // outright (ALREADY_STARTED).
      await EmulatorProcess.stop();
      if (await EmulatorProcess.launch(file.path, sharedFramePath: shared)) {
        // Attach on this side too, so the panel draws what the other process
        // renders. Everything above the accessors is unchanged: the view still
        // polls a counter and copies a frame.
        //
        // Retried, because the mapping does not exist yet when launch()
        // returns: the other process has to start a Flutter engine and reach
        // the core before it creates the file. A single attempt here fails
        // silently and the panel stays black with the session apparently
        // running - which is exactly what it looked like.
        if (!mounted) return;
        setState(() {
          _session = entry;
          _pendingArchiveSetup = archiveSetup;
          _launchError = null;
          // The panel has to actually show the machine. Without this the
          // workbench stays on the library: the engine runs, frames cross the
          // process boundary and are read here - the counter proved it - and
          // none of it is on screen, because the emulator view is never built.
          _tab = WorkbenchTab.running;
        });
        // AFTER the session is set, not before.
        //
        // unawaited() starts the loop synchronously, and its first act is to
        // give up if there is no session - so starting it first meant it read
        // a _session that setState had not assigned yet and returned on
        // iteration zero. No attach, and no timeout either, which is why the
        // panel stayed black in silence.
        unawaited(_attachWhenReady(shared));
        return;
      }
      if (!mounted) return;
      setState(
        () => _launchError = 'Could not start ${entry.title}.',
      );
      return;
    }

    var result = widget.core.start(file.path);
    if (result == RetroDosboxResult.alreadyStarted) {
      // In-process only, which now means desktop: the core is one-shot, so a
      // second start in the same process is refused outright and there is no
      // teardown that would make it possible. Android does not reach here -
      // it runs the engine in its own process, where ending a session is
      // ending that process.
      _emulatorUi.reset();
      if (!mounted) return;
      setState(
        () => _launchError =
            'A session is already running. Close it before starting '
            '${entry.title}.',
      );
      return;
    }
    if (!mounted) return;
    if (result != RetroDosboxResult.ok) {
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

  /// Closes the running session and returns to the library.
  ///
  /// "Close" here means terminate: the core is asked to stop and any paused
  /// snapshot of this title is also dropped, because it lives in-process in
  /// the same core instance we are about to shut down. This is the X
  /// button -- a clean kill with no resume path. Contrast with [_onSessionPause]
  /// above, which preserves the snapshot and only navigates away.
  ///
  /// Persists any archive saves before tearing down (otherwise writes
  /// against the cached C: drive never make it back to saveRoot).
  Future<void> _onSessionExit() async {
    final setup = _pendingArchiveSetup;
    if (setup != null) {
      await ZipRunner.persistSaves(
        cacheRoot: setup.cacheRoot,
        saveRoot: setup.saveRoot,
      );
    }
    if (!mounted) return;

    _emulatorUi.reset();

    // Stop the ENGINE's process, not this one.
    //
    // Restarting the whole app was the right answer only while the core lived
    // in here: a one-shot core with no teardown could not be freed any other
    // way. Now it runs in :dosbox, so ending a session is ending that service
    // - Android reclaims whatever the engine leaked, the next game gets a
    // fresh core, and the launcher never goes anywhere. Closing a game should
    // not close the launcher with it.
    if (EmulatorProcess.isSupported) {
      await EmulatorProcess.stop();
      widget.core.detachSharedFrameIfAttached();
      if (!mounted) return;
      setState(() {
        _session = null;
        _pendingArchiveSetup = null;
        _pausedSession = null;
        _tab = WorkbenchTab.games;
      });
      return;
    }

    // No restart mechanism (desktop, or the host refused): fall back to the
    // old attempt so there is at least a chance, and say so if it fails.
    widget.core.stop();
    if (!mounted) return;
    setState(() {
      _session = null;
      _pendingArchiveSetup = null;
      _pausedSession = null;
      _tab = WorkbenchTab.games;
    });
  }

  /// Pauses the running session and returns to the library.
  ///
  /// The engine stays up, stopped where it was, and [_pausedSession] gives the
  /// library its Resume affordance while [_session] clears so the emulator
  /// screen is no longer drawn.
  ///
  /// No save state is taken on Android, and that is not a shortcut. The engine
  /// is a live process of its own there, so pausing it IS the snapshot -- the
  /// whole machine sits exactly where it was, which is better than any slot.
  /// Writing one would only have been a way of surviving the process going
  /// away, which was the old restart-the-app design, and the call was reaching
  /// this launcher's idle core object and doing nothing anyway. Desktop still
  /// takes one, because there the core and the app share a fate.
  Future<void> _onSessionPause() async {
    final session = _session;
    if (session == null) return;
    if (EmulatorProcess.isSupported) {
      await EmulatorProcess.setPaused(true);
    } else {
      widget.core.saveState(0);
      widget.core.setPaused(true);
    }
    // Trackpad mouse and the keyboard are per-session: coming back to a
    // different title in a mode you did not choose is a puzzle, not a
    // convenience.
    _emulatorUi.reset();
    if (!mounted) return;
    setState(() {
      _session = null;
      _pausedSession = session;
      _tab = WorkbenchTab.games;
    });
  }

  /// Resumes the paused session and jumps back to the emulator screen.
  ///
  /// Nothing is started and nothing is restored: the engine has been sitting
  /// paused since [_onSessionPause], so resuming is simply letting it run
  /// again. On desktop the saved slot is loaded first, because there the pause
  /// and the snapshot are the same gesture.
  void _onResumePaused() {
    final paused = _pausedSession;
    if (paused == null) return;
    if (EmulatorProcess.isSupported) {
      unawaited(EmulatorProcess.setPaused(false));
    } else {
      widget.core.loadState(0);
      widget.core.setPaused(false);
    }
    if (!mounted) return;
    setState(() {
      _session = paused;
      _pausedSession = null;
      _tab = WorkbenchTab.running;
    });
  }

  /// Shows the in-game chrome and restarts its countdown.
  ///
  /// Called on every touch anywhere in the session, through a Listener that
  /// does not consume the event -- so the same tap that brings the toolbar
  /// back is still the tap the game receives. Anything else would make
  /// revealing the controls cost you a shot.
  void _pokeChrome() {
    _chromeTimer?.cancel();
    if (!_chromeVisible) setState(() => _chromeVisible = true);
    _chromeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _chromeVisible = false);
    });
  }

  /// Hides the system bars while a machine is on screen, and gives them back
  /// when it is not.
  ///
  /// Sticky rather than plain immersive: a swipe from the edge of a handheld
  /// is easy to do by accident mid-game, and sticky brings the bars back
  /// transiently instead of leaving them up over the picture.
  void _syncImmersive(bool wanted) {
    if (wanted == _immersive) return;
    _immersive = wanted;
    SystemChrome.setEnabledSystemUIMode(
      wanted ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (wanted) {
      // Visible on arrival, then gone: the player needs to see the controls
      // exist before they can learn a tap brings them back.
      _pokeChrome();
    } else {
      _chromeTimer?.cancel();
      _chromeVisible = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;

    // A running machine takes the whole screen: no rail, no status row, no
    // panel border. Those are library furniture, and a 4:3 picture on a wide
    // handheld has no height to lend them.
    final fullscreen = _session != null && _tab == WorkbenchTab.running;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _syncImmersive(fullscreen));
    if (fullscreen) return _fullscreenSession();
    return Container(
      color: RetroDosboxColors.rootBackground,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(RetroDosboxMetrics.rootPadding),
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_sidebarHidden) ...[
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: RetroDosboxMetrics.sidebarMaxWidth(screenWidth),
                        ),
                        child: Sidebar(
                          destinations: [
                            for (final tab in WorkbenchTab.values)
                              SidebarDestination(
                                tab.title,
                                icon: tab.icon,
                                group: tab.group,
                              ),
                          ],
                          selectedIndex: _tab.index,
                          onSelected: (i) =>
                              setState(() => _tab = WorkbenchTab.values[i]),
                          style: retroDosboxSidebarStyle,
                          pinLastGroupToBottom: true,
                        ),
                      ),
                      const SizedBox(width: RetroDosboxMetrics.contentLeftMargin),
                    ],
                    Expanded(child: _contentPanel()),
                  ],
                ),
              ),
              _statusBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// The bottom strip, outside both the sidebar and the content panel: the
  /// sidebar show/hide toggle plus the name of the running title. It always
  /// renders, even with no session and even with the sidebar hidden -- the
  /// toggle is the only way back once the rail is gone, so it cannot live
  /// inside the rail it controls.
  ///
  /// When the user has paused a session the running title is gone from the
  /// emulator screen but still alive in [_pausedSession]; the status bar
  /// surfaces that, with a tap target to resume rather than just text.
  Widget _statusBar() {
    final session = _session;
    final paused = _pausedSession;
    final shown = session ?? paused;
    // A little taller while a machine is running - the buttons are still
    // finger sized - but only a little: every pixel this row takes is a pixel
    // the picture does not get. Same treatment as the Amiga strip.
    return SizedBox(
      height: session != null ? 36 : 28,
      child: Row(
      children: [
        IconButton(
          onPressed: () {
            setState(() => _sidebarHidden = !_sidebarHidden);
            AppPrefs.setSidebarHidden(_sidebarHidden);
          },
          icon: Icon(
            _sidebarHidden ? Icons.menu : Icons.menu_open,
            size: 20,
          ),
          color: RetroDosboxColors.textMuted,
          tooltip: _sidebarHidden ? 'Show sidebar' : 'Hide sidebar',
          visualDensity: VisualDensity.compact,
        ),
        if (shown != null)
          Expanded(
            child: GestureDetector(
              // The status bar doubles as a resume affordance when there is a
              // paused session -- tapping it switches to the Running tab and
              // restores the snapshotted state. The emulator screen's pause
              // toolbar covers this for the in-session case; this is the
              // counterpart visible after the user has gone back to the library.
              behavior: HitTestBehavior.opaque,
              onTap: paused != null ? _onResumePaused : null,
              child: Text(
                // The outer if (shown != null) ensures both branches have
                // a non-null title to pull from, so the casts are sound.
                session != null
                    ? (widget.core.isPaused
                        ? 'PAUSED — ${session.title}'
                        : session.title)
                    : 'PAUSED — ${paused!.title} (tap to resume)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RetroDosboxTextStyles.statusLine,
              ),
            ),
          ),
        // Right-hand end of the row, and only while a machine is actually
        // running: the strip is the in-game chrome, not a permanent fixture.
        if (session != null) ...[
          const Spacer(),
          EmulatorControlStrip(
            ui: _emulatorUi,
            onPause: _onSessionPause,
            onExit: _onSessionExit,
          ),
        ],
      ],
      ),
    );
  }

  /// The running machine, edge to edge, with the toolbar floating over it.
  ///
  /// The toolbar overlays the picture here, which everywhere else in this app
  /// it deliberately does not: on the library screens it sits on the status
  /// row below the panel. Fullscreen leaves no row to sit on, so it keeps the
  /// same place it has everywhere else -- along the bottom, from the right --
  /// and earns it by getting out of the way: three seconds after the last
  /// touch it is gone.
  ///
  /// Bottom rather than top. The top-right is where DOS titles put their own
  /// status panels, and it is also not where this app's toolbar lives on any
  /// other screen, or where the Amiga and C64 front ends put theirs.
  Widget _fullscreenSession() {
    return Listener(
      // Translucent, and onPointerDown rather than a tap: this has to observe
      // the touch without eating it, so the game still gets it.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _pokeChrome(),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(child: _tabContent()),
            Positioned(
              bottom: 0,
              right: 0,
              child: SafeArea(
                child: AnimatedOpacity(
                  opacity: _chromeVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  // Faded-out chrome must not still be catching taps meant for
                  // the game underneath it.
                  child: IgnorePointer(
                    ignoring: !_chromeVisible,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: EmulatorControlStrip(
                        ui: _emulatorUi,
                        onPause: _onSessionPause,
                        onExit: _onSessionExit,
                        onInteract: _pokeChrome,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contentPanel() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: RetroDosboxColors.panelFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: RetroDosboxColors.panelStroke),
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
        color: RetroDosboxColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: RetroDosboxColors.warning),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: RetroDosboxColors.warning, fontSize: 12),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _launchError = null),
            icon: const Icon(Icons.close, size: 16),
            color: RetroDosboxColors.warning,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// Banner above the library when a snapshotted session is waiting to be
  /// resumed. Tap to resume, or tap the X to drop the snapshot (does not
  /// kill the underlying paused core -- the only thing the user can do
  /// about a wedged core is restart the app, same as before).
  Widget _resumableBanner(GameEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: RetroDosboxColors.accentAmber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: RetroDosboxColors.accentAmber),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, size: 16,
              color: RetroDosboxColors.accentAmber),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onResumePaused,
              child: Text(
                'Paused: ${entry.title} — tap to resume',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: RetroDosboxColors.accentAmber, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Full-card Resume/Discard view shown on the Running tab when a session
  /// has been paused. Distinct from [_resumableBanner] above, which lives
  /// above the games grid and offers only resume. This is the canonical
  /// destination when the user navigates to "Running" with no live session,
  /// and adds a Discard button for the case where the snapshot should be
  /// thrown away (e.g. the game was paused by mistake) without forcing the
  /// user back to the library to find that affordance.
  Widget _pausedSessionView(GameEntry entry) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: RetroDosboxColors.panelFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: RetroDosboxColors.accentAmber),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history,
                size: 28, color: RetroDosboxColors.accentAmber),
            const SizedBox(height: 10),
            const Text(
              'Paused session',
              style: TextStyle(
                  color: RetroDosboxColors.accentAmber,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              entry.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline,
                      color: RetroDosboxColors.textMuted2),
                  label: const Text('Discard',
                      style:
                          TextStyle(color: RetroDosboxColors.textMuted2)),
                  onPressed: _discardPausedSession,
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                  onPressed: _onResumePaused,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Drops [_pausedSession] without resuming. The core stays paused but
  /// orphaned; until the user either resumes or kills it via the toolbar X
  /// in the emulator screen, the snapshot in slot 0 sits unused.
  ///
  /// Why a separate Discard from X: X tears the core down, ending the
  /// "one core per process" lifecycle. Discard only clears the Dart-side
  /// pointer; the core is still running with the snapshot in slot 0. The
  /// user can then launch a different game (no -- actually no they can't,
  /// the running core still says alreadyStarted). Discard is therefore
  /// really "I don't want this snapshot anymore, take me back to the
  /// library" and is equivalent to clicking the same title in the games
  /// grid -- but the latter goes through the launcher flow, which writes
  /// the conf file again. Both are intentional exits from the paused
  /// state.
  void _discardPausedSession() {
    setState(() => _pausedSession = null);
  }

  Widget _tabContent() {
    switch (_tab) {
      case WorkbenchTab.games:
        if (_scanning) return const Center(child: CircularProgressIndicator());
        return Column(
          children: [
            if (_pausedSession != null) _resumableBanner(_pausedSession!),
            Expanded(
              child: LibraryGrid(
                entries: _entries,
                unreadable: _unreadable,
                onLaunch: _launch,
                onShowDetails: _showDetails,
                onRescan: _rescan,
                onAddGame: _addGame,
              ),
            ),
          ],
        );
      case WorkbenchTab.running:
        final session = _session;
        if (session != null) {
          return EmulatorScreen(
            ui: _emulatorUi,
            core: widget.core,
            input: _input,
            title: session.title,
            controllerConnected: _controllerConnected,
            onExit: () => unawaited(_onSessionExit()),
            onPause: () => unawaited(_onSessionPause()),
          );
        }
        final paused = _pausedSession;
        if (paused != null) {
          // A session is paused and the user has navigated to the Running tab
          // (the sidebar still routes there even though [_session] is null).
          // The library banner also offers resume; this is the
          // canonical-destination counterpart, with both Resume and
          // Discard visible.
          return _pausedSessionView(paused);
        }
        return const Center(
          child: Text(
            'No session running. Pick a title from Games.',
            style: TextStyle(color: RetroDosboxColors.textMuted),
          ),
        );
      case WorkbenchTab.video:
        return const VideoSettingsScreen();
      case WorkbenchTab.input:
        return InputSettingsScreen(
          core: widget.core,
          controllerConnected: _controllerConnected,
        );
      case WorkbenchTab.engine:
        return RetroDosboxConfigScreen(core: widget.core);
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
      backgroundColor: RetroDosboxColors.cardFill,
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
              style: TextStyle(color: RetroDosboxColors.textMuted2, fontSize: 12),
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
                style: TextStyle(fontSize: 11, color: RetroDosboxColors.textMuted),
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
                style: TextStyle(color: RetroDosboxColors.textMuted2, fontSize: 12),
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
