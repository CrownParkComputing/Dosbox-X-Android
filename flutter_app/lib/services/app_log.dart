// app_log.dart — A log the user can actually send me.
//
// Mirrors ViceMultiplatform's AppLog. Records Dart-side events to
// memory + a file under the app's per-platform data dir.
//
// The log file lives under the app-support dir's logs/ folder. The user grabs it via the in-app Logs
// screen (which renders the in-memory tail + reads the file back),
// which is the access path that works identically on Android, iOS,
// and Linux. The previous incarnation wrote to the Android external
// files dir so the file showed up in the Files app, which was the
// right thing for Android but iOS-specific support (UIFileSharingEnabled
// + LSSupportsOpeningDocumentsInPlace) made the iOS twin awkward,
// and Linux has no equivalent.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppLog {
  /// Serialises file appends without blocking the UI thread.
  static Future<void> _pendingWrite = Future<void>.value();

  AppLog._();

  /// Lines logged from Dart this session. Bounded so the log doesn't
  /// grow unbounded for hours-long sessions.
  static final List<String> _lines = <String>[];
  static const int _maxLines = 2000;

  static String? _filePath;
  static bool _initialized = false;

  /// Where the log file lives, once [init] has run.
  static String? get filePath => _filePath;

  /// One-shot setup. Idempotent. Resolves the per-platform data dir
  /// via [YmirCorePaths], then ensures the `logs/` subdir exists.
  /// [YmirCorePaths.ensureDirs] runs at app startup so the dir is
  /// already there; this is the safety net.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final support = await getApplicationSupportDirectory();
      final path = p.join(support.path, 'logs', 'retrodosbox.log');
      final dir = Directory(p.dirname(path));
      if (!dir.existsSync()) await dir.create(recursive: true);
      _filePath = path;
    } catch (e) {
      _append('log init failed: $e');
    }
  }

  /// Records a line, to memory and to the file.
  static void log(String message) {
    final stamp = DateTime.now().toIso8601String().substring(11, 23);
    final line = '$stamp  $message';
    _append(line);
    final path = _filePath;
    if (path == null) return;
    try {
      // Async, deliberately: this ran a synchronous append on the UI thread
      // for every single log line, and the log file can live on an SD card --
      // one busy moment on the card and every logged event became a UI stall.
      // Ordering is preserved by the future chain; a log write must never
      // block the frame it is reporting on.
      _pendingWrite = _pendingWrite.then(
        (_) => File(path).writeAsString('$line\n', mode: FileMode.append),
      );
    } catch (_) {
      // A log write must never take the app down.
    }
  }

  static void _append(String line) {
    _lines.add(line);
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }

  /// Everything worth showing: the Dart lines this session.
  /// Reads the file rather than returning [_lines], so we see lines
  /// from any process that wrote to the file.
  static Future<String> read() async {
    final path = _filePath;
    if (path == null) return _lines.join('\n');
    try {
      final text = await File(path).readAsString();
      return text.isEmpty ? _lines.join('\n') : text;
    } catch (e) {
      return '${_lines.join('\n')}\n(could not read $path: $e)';
    }
  }

  /// Empties the log, keeping a header so a fresh report says when it started.
  static Future<void> clear() async {
    _lines.clear();
    final path = _filePath;
    if (path == null) return;
    try {
      await File(path).writeAsString(
          '=== cleared ${DateTime.now().toIso8601String()} ===\n');
    } catch (_) {}
  }
}