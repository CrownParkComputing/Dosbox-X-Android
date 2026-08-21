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
