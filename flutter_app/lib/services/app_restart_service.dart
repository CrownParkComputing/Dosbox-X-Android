// Restarts the Android app process after a DOSBox session.
//
// DOSBox-X is a one-shot native core in this embedding: its upstream globals
// do not have a complete teardown path, so a second start in the same process
// is unsafe. Android can solve that cleanly by scheduling its launcher
// activity and then ending the current process. The fresh process returns to
// the library with a fresh core.
import 'dart:io';

import 'package:flutter/services.dart';

class AppRestartService {
  AppRestartService._();

  static const MethodChannel _channel = MethodChannel(
    'dosbox_multiplatform/app_restart',
  );

  /// Schedules an Android process restart. Returns false where this mechanism
  /// is unavailable so the UI can report the core's teardown limitation.
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
