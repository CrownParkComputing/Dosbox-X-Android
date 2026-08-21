// Restarts the Android app process after a DOSBox session.
//
// DOSBox-X is a one-shot native core in this embedding: its upstream globals
// have no complete teardown path, so a second start in the same process is
// unsafe. Worse, the Quit that dosbox_core_stop relies on is delivered through
// the frame-publish hook, and a core that has stopped rendering never reaches
// it -- so stop() times out and leaves the core wedged: started, unstoppable,
// and refusing every later launch. That is what "a session is already running"
// really meant.
//
// Android solves it cleanly: schedule the launcher activity, end this process,
// and the fresh one comes back to the library with a fresh core. Save states
// live on disk, so nothing a player cared about goes with the process.
import 'dart:io';

import 'package:flutter/services.dart';

/// Hands a title to the emulator process.
///
/// The core runs in :dosbox rather than here, so a session is a process: it
/// ends by ending, and the next game gets a genuinely fresh engine while this
/// launcher is never touched. See DosboxEmulatorActivity.
class EmulatorProcess {
  EmulatorProcess._();

  static const MethodChannel _channel = MethodChannel(
    'com.crownpark.retrodosbox/storage_permissions',
  );

  /// True where the emulator runs out-of-process. Desktop keeps the
  /// in-process FFI path, which is fine there: it is not a one-shot core
  /// problem when the whole app is the session.
  static bool get isSupported => Platform.isAndroid;

  /// Starts [confPath] in the emulator process. Returns false if the host has
  /// no such mechanism, so the caller can fall back rather than appear to
  /// ignore the tap.
  static Future<bool> launch(
    String confPath, {
    required String sharedFramePath,
    int maxWidth = 1024,
    int maxHeight = 768,
  }) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('launchEmulator', <String, Object>{
            'confPath': confPath,
            'sharedFramePath': sharedFramePath,
            'maxWidth': maxWidth,
            'maxHeight': maxHeight,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Pauses or resumes the engine in the emulator process.
  static Future<void> setPaused(bool paused) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('setEmulatorPaused', <String, Object>{
        'paused': paused,
      });
    } on PlatformException {
      // Nothing running.
    } on MissingPluginException {
      // Not this host.
    }
  }

  /// Sends one input event to the running session.
  ///
  /// Fire-and-forget by design: input is continuous, and awaiting a reply per
  /// keypress would put a binder round trip between a held direction and the
  /// game reacting to it. A dropped event during teardown is the right
  /// outcome, so failures are swallowed rather than reported.
  static void sendInput(
    String kind, {
    int a = 0,
    int b = 0,
    double x = 0,
    double y = 0,
    bool down = false,
  }) {
    if (!isSupported) return;
    _channel.invokeMethod<bool>('emulatorInput', <String, Object>{
      'kind': kind,
      'a': a,
      'b': b,
      'x': x,
      'y': y,
      'down': down,
    }).catchError((Object _) => false);
  }

  /// Ends the session by ending the process.
  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('stopEmulator');
    } on PlatformException {
      // Nothing running.
    } on MissingPluginException {
      // Not this host.
    }
  }
}

class AppRestartService {
  AppRestartService._();

  static const MethodChannel _channel = MethodChannel(
    'com.crownpark.retrodosbox/storage_permissions',
  );

  /// Schedules an Android process restart. Returns false where the mechanism
  /// is unavailable, so the UI can say what happened rather than appearing to
  /// ignore the tap.
  static Future<bool> restart() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('restartApp') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
