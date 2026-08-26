// Shared-storage permission handling: all-files access, the Retro-Amiga way.
//
// A DOS collection is folders of .exe/.com/.bat plus .iso/.img/.zip -- none
// of them media types, so READ_MEDIA_* never applies and all-files access is
// the only permission that lets the app read a games folder the user chose
// IN PLACE. The whole Retro-* family now asks for it (Retro-Amiga shipped
// this way and passed Play's sensitive-permission review); the SAF folder
// grant remains as the fallback for anyone who declines.
import 'dart:io';

import 'package:flutter/services.dart';

class PermissionsService {
  PermissionsService._();

  static const MethodChannel _channel =
      MethodChannel('com.crownpark.retrodosbox/storage_permissions');

  /// Only Android gates raw-path reads this way.
  static bool get isRelevant => Platform.isAndroid;

  /// True if the app can currently read arbitrary files out of shared
  /// storage. Always true where the concept doesn't apply.
  static Future<bool> hasStorageAccess() async {
    if (!isRelevant) return true;
    try {
      return await _channel.invokeMethod<bool>('hasSharedStorageAccess') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Asks for shared-storage access. On Android 11+ this opens the system
  /// "All files access" settings page for this app and waits for the user
  /// to come back. Returns whether access was granted.
  static Future<bool> requestStorageAccess() async {
    if (!isRelevant) return true;
    try {
      return await _channel
              .invokeMethod<bool>('requestSharedStorageAccess')
              .timeout(const Duration(seconds: 90)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Check, ask if needed, re-check. The one call sites use.
  static Future<bool> ensure() async {
    if (await hasStorageAccess()) return true;
    return requestStorageAccess();
  }
}
