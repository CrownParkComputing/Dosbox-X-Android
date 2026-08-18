// Shared-storage permission handling (Android only).
//
// Why this exists: on Android 11+ the app could LIST the user's
// /storage/emulated/0/Dosbox/Games tree without any permission, so the
// library grid filled up with titles -- but reading a file's bytes returned
// nothing, so the native core got a path it could not open and the emulator
// screen came up blank with no explanation. DOS media (.iso/.img/.zip, or a
// game folder full of .exe/.com/.bat files) is not images/video/audio, so
// READ_MEDIA_* does not apply; "All files access"
// (MANAGE_EXTERNAL_STORAGE) is what actually grants the read.
//
// Implemented as a two-method platform channel into MainActivity.kt rather
// than via the permission_handler package: that package's current Android
// artifact does not compile against this project's Gradle/Kotlin setup, and
// all we need is isExternalStorageManager() plus the Settings intent.
//
// The permission cannot be granted by an in-app dialog -- request() sends
// the user out to a system Settings toggle -- so callers must re-check when
// the app comes back rather than trusting the immediate return value.
import 'dart:io';

import 'package:flutter/services.dart';

class PermissionsService {
  PermissionsService._();

  static const MethodChannel _channel =
      MethodChannel('dosbox_multiplatform/storage_permissions');

  /// Whether this platform needs (and can be granted) shared-storage access
  /// at all. Linux has ordinary filesystem access; iOS imports files into
  /// the sandbox instead.
  static bool get isRelevant => Platform.isAndroid;

  /// True if the app can currently read arbitrary files out of shared
  /// storage. Always true where the concept doesn't apply.
  static Future<bool> hasStorageAccess() async {
    if (!isRelevant) return true;
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks for shared-storage access. On Android 11+ this opens the system
  /// "All files access" settings page for this app; the returned value is
  /// the state as of when the call returns, so callers should re-check
  /// after the user comes back.
  static Future<bool> requestStorageAccess() async {
    if (!isRelevant) return true;
    try {
      return await _channel.invokeMethod<bool>('requestAllFilesAccess') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
