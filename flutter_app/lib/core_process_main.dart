// The entry point of the emulator process.
//
// DOSBox-X is a one-shot core: its upstream globals have no teardown path, so
// a session can only really end by ending a process. That is why the engine
// runs here, in :dosbox, rather than inside the launcher -- ending a game ends
// this process, Android reclaims whatever the engine leaked, and the next game
// gets a genuinely fresh core while the launcher never goes anywhere.
//
// It runs a Flutter engine with no UI at all, purely so this code can reach
// the core through the same FFI bindings the launcher uses. Writing it in
// Kotlin instead would have meant a JNI wrapper around the whole bridge ABI,
// and another rebuild of both cores to add it.
//
// The picture goes back to the launcher through a shared mapping rather than a
// window: the engine renders offscreen, publishes into the mapping, and the
// launcher draws it in its own panel, under its own controls. See
// dosbox_core_set_shared_frame.
import 'dart:async';

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'ffi/retrodosbox_native_paths.dart';
import 'services/engine_config.dart';

import 'ffi/retrodosbox_bindings.dart';
import 'ffi/retrodosbox_core.dart';

/// Kept alive for the life of the process: the core is running inside it.
RetroDosboxCore? _core;

@pragma('vm:entry-point')
void dosboxCoreMain() {
  // Not runApp: there is no UI here. The engine exists so this isolate can
  // talk to the core and to the host.
  WidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.crownpark.retrodosbox/core_process');
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'start':
        final args = (call.arguments as Map).cast<String, Object?>();
        return await _start(
          confPath: args['confPath'] as String? ?? '',
          sharedFramePath: args['sharedFramePath'] as String? ?? '',
          maxWidth: (args['maxWidth'] as num?)?.toInt() ?? 1024,
          maxHeight: (args['maxHeight'] as num?)?.toInt() ?? 768,
        );

      // Ending a session means ending this process. Nothing is torn down
      // first, deliberately: a core with no teardown path cannot be asked to
      // clean up, and the whole point of being a separate process is that it
      // does not have to.
      case 'stop':
        _core = null;
        return true;

      // The launcher is gone from the screen; the engine is not, because it
      // is in another process Android has no reason to stop.
      case 'pause':
        final args = (call.arguments as Map).cast<String, Object?>();
        _core?.setPaused(args['paused'] as bool? ?? false);
        return true;

      // Everything the player touches is seen by the LAUNCHER process; the
      // engine that has to receive it is this one. See MainActivity's
      // emulatorInbox for why this arrives over a binding rather than the
      // intents that carry start and stop.
      case 'input':
        _input((call.arguments as Map).cast<String, Object?>());
        return true;

      case 'isRunning':
        return _core?.isRunning ?? false;

      default:
        throw MissingPluginException('unknown method ${call.method}');
    }
  });

  // Tell the host we are ready to be given a title. Without this the host
  // would have to guess when the Dart isolate had finished starting, and a
  // start() that lands too early is a session that silently never begins.
  channel.invokeMethod<void>('ready');
}

/// Applies one input event to the running core.
///
/// Silently does nothing when no session is running: input can be in flight
/// while a session is ending, and a dropped keypress is the correct outcome
/// there.
void _input(Map<String, Object?> event) {
  final core = _core;
  if (core == null) return;
  final a = (event['a'] as num?)?.toInt() ?? 0;
  final b = (event['b'] as num?)?.toInt() ?? 0;
  final down = event['down'] as bool? ?? false;
  switch (event['kind'] as String?) {
    case 'key':
      core.keyEvent(a, down);
    case 'mouseMotion':
      core.mouseMotion(a, b);
    case 'cdInsert':
      core.cdInsert(event['text'] as String? ?? '');
    case 'configSet':
      core.configSet(
        event['text'] as String? ?? '',
        event['text2'] as String? ?? '',
        event['text3'] as String? ?? '',
      );
    case 'mousePosition':
      core.mousePosition(
        (event['x'] as num?)?.toDouble() ?? 0,
        (event['y'] as num?)?.toDouble() ?? 0,
      );
    case 'mouseButton':
      core.mouseButton(a, down);
    case 'joystick':
      core.joystick(
        a,
        b,
        axisX: (event['x'] as num?)?.toDouble() ?? 0,
        axisY: (event['y'] as num?)?.toDouble() ?? 0,
      );
  }
}

/// Picks a video driver SDL can actually initialise here.
///
/// SDL's Android video backend expects an Activity, and this process has none:
/// SDL_VideoInit dereferenced a null and took the process down with SIGSEGV,
/// through SDL_main -> SDL_InitSubSystem -> SDL_VideoInit.
///
/// The engine does not need a window anyway - it renders offscreen through the
/// gamelink output and publishes finished frames into the shared mapping - so
/// the dummy driver is not a compromise, it is what this process actually
/// wants. Set before the core loads, because SDL reads it at init.
void _useHeadlessVideo() {
  final setenv = DynamicLibrary.process().lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');
  final name = 'SDL_VIDEODRIVER'.toNativeUtf8();
  final value = 'dummy'.toNativeUtf8();
  try {
    setenv(name, value, 1);
  } finally {
    malloc.free(name);
    malloc.free(value);
  }
}

Future<bool> _start({
  required String confPath,
  required String sharedFramePath,
  required int maxWidth,
  required int maxHeight,
}) async {
  if (confPath.isEmpty || sharedFramePath.isEmpty) return false;

  _useHeadlessVideo();

  final RetroDosboxCoreBindings core;
  try {
    core = RetroDosboxCoreBindings.load(
        libraryPath: RetroDosboxNativePaths.coreLibraryPath);
  } on Object {
    // No core, no session. Unlike the launcher there is no stub worth falling
    // back to here: this process exists only to run the engine.
    return false;
  }

  // The resource directory, before anything else touches the core.
  //
  // DOSBox-X opens its own data files by path - fonts, translations, the
  // shipped dosbox-x.conf template, glshaders - and the bridge header is
  // explicit that this comes before start(). The launcher does it at app
  // startup; this process is a different process and has to do it for itself.
  // Without it the engine comes up unable to find any of that and never
  // reaches the title.
  core.init(await RetroDosboxNativePaths.resolveResourceDir());

  // Before start, not after: the engine publishes its first frame during boot,
  // and a mapping attached later would miss it -- which looks like a machine
  // that never started rather than a picture that arrived late.
  final shared = core.setSharedFrame(sharedFramePath, maxWidth, maxHeight);
  debugPrint('dosbox-core: setSharedFrame($sharedFramePath) -> $shared');
  if (!shared) return false;

  final started = core.start(confPath);
  debugPrint('dosbox-core: start -> $started');
  if (started != RetroDosboxResult.ok) return false;
  _core = core;

  // Publish what this engine knows about itself, so the launcher's settings
  // screen has something to render. It cannot ask us -- the channel only runs
  // one way -- so we tell it, once, where it knows to look. See EngineConfig.
  //
  // Deferred rather than immediate: start() is asynchronous and the config
  // system is not fully populated until the machine has actually come up.
  // Asking too early yields an empty section list, which the launcher would
  // cache as "this engine has no settings".
  unawaited(_publishConfigWhenReady(core));
  return true;
}

/// Waits for the machine to be up, then writes the config dump.
///
/// Polling rather than a callback because the bridge offers no "started"
/// signal beyond is_running, and bounded because a machine that never comes
/// up must not leave a task waiting on it for the life of the process.
Future<void> _publishConfigWhenReady(RetroDosboxCore core) async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!core.isRunning) continue;
    if (core.configSections().isEmpty) continue;
    await publishEngineConfig(core);
    return;
  }
}
