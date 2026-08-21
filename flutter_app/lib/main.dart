// App entry point: load the core, decide whether to run the wizard, hand off
// to the workbench.
//
// State management is setState plus a handful of singletons, matching the VICE
// app. That is a deliberate choice rather than an omission: the genuinely
// shared, long-lived state in this app is the emulator core, and a core is a
// process-wide native resource with a single owner, not something that benefits
// from a reactive graph.
import 'package:flutter/material.dart';

import 'ffi/retrodosbox_bindings.dart';
import 'ffi/retrodosbox_core.dart';
import 'ffi/retrodosbox_native_paths.dart';
import 'ffi/stub_retrodosbox_core.dart';
import 'screens/setup_wizard_screen.dart';
import 'screens/workbench_screen.dart';
import 'services/app_prefs.dart';
import 'services/video_settings.dart';
import 'theme/retrodosbox_theme.dart';

void main() {
  runApp(const RetroDosboxApp());
}

class RetroDosboxApp extends StatefulWidget {
  const RetroDosboxApp({super.key});

  @override
  State<RetroDosboxApp> createState() => _DosboxAppState();
}

class _DosboxAppState extends State<RetroDosboxApp> with WidgetsBindingObserver {
  RetroDosboxCore? _core;

  /// True when [_core] is the stub rather than the real native library, so the
  /// UI can say so instead of looking broken.
  bool _usingStub = false;

  bool? _setupCompleted;
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
    final setupCompleted = await AppPrefs.isSetupCompleted();

    RetroDosboxCore core;
    bool usingStub;
    try {
      core = RetroDosboxCoreBindings.load(
          libraryPath: RetroDosboxNativePaths.coreLibraryPath);
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
      debugPrint('dosbox: falling back to the stub core. '
          'path=${RetroDosboxNativePaths.coreLibraryPath} error=$e');
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
        _pausedByLifecycle = false;
      }
    } else {
      // Idempotent across the multi-event transition: only the first
      // non-resumed event pauses and marks; later ones see the mark and do
      // nothing.
      if (!_pausedByLifecycle && !core.isPaused) {
        core.setPaused(true);
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
        onComplete: () => setState(() => _setupCompleted = true),
      );
    }
    return Column(
      children: [
        if (_usingStub) const _StubBanner(),
        Expanded(
          child: WorkbenchScreen(
            core: core,
            onRunSetupWizard: () =>
                setState(() => _setupCompleted = false),
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
        12, 6 + MediaQuery.paddingOf(context).top, 12, 6),
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
