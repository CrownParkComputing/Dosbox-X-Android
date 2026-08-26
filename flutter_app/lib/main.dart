// App entry point: load the core, decide whether to run the wizard, hand off
// to the workbench.
//
// State management is setState plus a handful of singletons, matching the VICE
// app. That is a deliberate choice rather than an omission: the genuinely
// shared, long-lived state in this app is the emulator core, and a core is a
// process-wide native resource with a single owner, not something that benefits
// from a reactive graph.
// Imported so the emulator process's entrypoint survives into the release
// snapshot. Release builds are AOT-compiled from what is reachable, and a file
// nothing imports is not compiled at all - so dosboxCoreMain existed in the
// source, was annotated as an entry point, and still could not be resolved:
// "Could not resolve main entrypoint function". Same reason Retro-Amiga's
// main.dart imports its overlay entrypoint.
import 'services/app_log.dart';
import 'dart:async';

import 'core_process_main.dart' show dosboxCoreMain;
import 'services/app_restart_service.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'ffi/retrodosbox_bindings.dart';
import 'ffi/retrodosbox_core.dart';
import 'ffi/retrodosbox_native_paths.dart';
import 'ffi/stub_retrodosbox_core.dart';
import 'screens/setup_wizard_screen.dart';
import 'screens/workbench_screen.dart';
import 'services/app_prefs.dart';
import 'services/video_settings.dart';
import 'theme/retrodosbox_theme.dart';

/// Referenced so the emulator process's entrypoint cannot be tree-shaken.
///
/// The import alone is not proof of use, and an unused import is exactly what
/// the analyzer offers to delete. This is never called: it exists so the
/// function is reachable, which is what puts it in the snapshot the service's
/// FlutterEngine looks it up by name in.
// ignore: unused_element
const _keepCoreEntrypoint = dosboxCoreMain;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Fire-and-forget: the log must never delay first frame, and early
  // lines are buffered in memory until the file is ready.
  unawaited(AppLog.init());
  runApp(const RetroDosboxApp());
}

class RetroDosboxApp extends StatefulWidget {
  const RetroDosboxApp({super.key});

  @override
  State<RetroDosboxApp> createState() => _DosboxAppState();
}

class _DosboxAppState extends State<RetroDosboxApp>
    with WidgetsBindingObserver {
  RetroDosboxCore? _core;

  /// True when [_core] is the stub rather than the real native library, so the
  /// UI can say so instead of looking broken.
  bool _usingStub = false;

  bool? _setupCompleted;
  String? _appBuild;

  /// True when the lifecycle handler paused the core (vs the user pausing it
  /// from the emulator screen). See didChangeAppLifecycleState.
  bool _pausedByLifecycle = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await VideoSettings.instance.load();

    // The setup/compliance choice is shown once per numbered build, not once
    // per installation. App upgrades preserve SharedPreferences, so a lone
    // setup_completed boolean would prevent testers and reviewers from ever
    // seeing revised first-run information.
    String? appBuild;
    try {
      final info = await PackageInfo.fromPlatform();
      appBuild = '${info.version}+${info.buildNumber}';
    } on Object catch (error) {
      // Package metadata can be unavailable under a test binding or on a new
      // platform integration. Fall back to the legacy boolean rather than
      // trapping that platform in a wizard on every launch.
      AppLog.log(
        'dosbox: app build unavailable; setup is not build-keyed: '
        '$error',
      );
    }
    final setupCompleted = appBuild == null
        ? await AppPrefs.isSetupCompleted()
        : await AppPrefs.setupCompletedForBuild(appBuild);

    RetroDosboxCore core;
    bool usingStub;
    try {
      core = RetroDosboxCoreBindings.load(
        libraryPath: RetroDosboxNativePaths.coreLibraryPath,
      );
      usingStub = false;
    } on Object catch (e) {
      // Falling back rather than failing: the native core is a separate, slow
      // build that CI cannot produce (see docs/NATIVE_BUILD.md), so an
      // absent .so is the normal state during UI work. Catching broadly is
      // intentional -- dlopen failures surface as several different error
      // types across platforms, and every one of them means the same thing.
      //
      // But it is reported, not swallowed: on a device the difference between
      // "no core was built" and "the core is there and dlopen refused it" is
      // invisible from the banner alone, and only this message distinguishes
      // them.
      AppLog.log(
        'dosbox: falling back to the stub core. '
        'path=${RetroDosboxNativePaths.coreLibraryPath} error=$e',
      );
      core = StubRetroDosboxCore();
      usingStub = true;
    }

    if (!usingStub) {
      final resourceDir = await RetroDosboxNativePaths.resolveResourceDir();
      core.init(resourceDir);
    }

    if (!mounted) return;
    setState(() {
      _core = core;
      _usingStub = usingStub;
      _appBuild = appBuild;
      _setupCompleted = setupCompleted;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final core = _core;
    if (core == null) return;
    if (state == AppLifecycleState.resumed) {
      // Only un-pause if we were the ones who paused it. Otherwise returning
      // from the background would resume a session the user had deliberately
      // paused. Tracked as "did we pause" rather than "was it paused before":
      // one backgrounding delivers SEVERAL non-resumed events (inactive,
      // hidden, paused), and re-reading core.isPaused on the second one sees
      // the pause WE just applied and records it as the user's -- the resume
      // then refuses to un-pause and the core stays frozen for good.
      if (_pausedByLifecycle) {
        core.setPaused(false);
        // And the engine itself, which lives in another process now: this
        // process's core object is not the one running the game.
        unawaited(EmulatorProcess.setPaused(false));
        _pausedByLifecycle = false;
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Only a REAL backgrounding pauses the machine. `inactive` fires for a
      // notification shade, a permission dialog, or losing window focus on
      // desktop -- pausing there freezes the game under a still-visible
      // window, which is the bug Retro-Amiga's live release taught us about.
      //
      // Idempotent across the multi-event transition: only the first
      // backgrounding event pauses and marks; later ones see the mark and do
      // nothing.
      if (!_pausedByLifecycle && !core.isPaused) {
        core.setPaused(true);
        unawaited(EmulatorProcess.setPaused(true));
        _pausedByLifecycle = true;
      }
    }
    // The pause state feeds visible text (the workbench status bar) and there
    // is no stream for it, so repaint explicitly.
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Retro-Dosbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: RetroDosboxColors.rootBackground,
        colorScheme: ColorScheme.fromSeed(
          seedColor: RetroDosboxColors.accentAmber,
          brightness: Brightness.dark,
        ),
      ),
      home: Scaffold(body: _home()),
    );
  }

  Widget _home() {
    final core = _core;
    final setupCompleted = _setupCompleted;
    if (core == null || setupCompleted == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!setupCompleted) {
      return SetupWizardScreen(
        appBuild: _appBuild,
        onComplete: () => setState(() => _setupCompleted = true),
      );
    }
    return Column(
      children: [
        if (_usingStub) const _StubBanner(),
        Expanded(
          child: WorkbenchScreen(
            core: core,
            onRunSetupWizard: () => setState(() => _setupCompleted = false),
          ),
        ),
      ],
    );
  }
}

/// Says plainly that no emulator is present.
///
/// Worth the screen space: without it, a stub session showing a test pattern
/// looks like a broken emulator rather than an absent one, and that is a
/// genuinely expensive confusion to debug.
class _StubBanner extends StatelessWidget {
  const _StubBanner();

  @override
  Widget build(BuildContext context) {
    // The banner is the topmost thing on screen, so on a device it lands under
    // the status bar: measured on an iPad, the clock and battery sat on top of
    // this text. SafeArea only on the top edge -- the sides and bottom belong
    // to the screens below.
    return Container(
      width: double.infinity,
      color: RetroDosboxColors.warning,
      padding: EdgeInsets.fromLTRB(
        12,
        6 + MediaQuery.paddingOf(context).top,
        12,
        6,
      ),
      child: Text(
        'Stub core: libdosboxcore not found, so nothing is being emulated. '
        'Build it with native/dosbox_core (see docs/NATIVE_BUILD.md).',
        style: const TextStyle(
          color: Colors.black,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
