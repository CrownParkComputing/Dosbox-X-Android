import 'dart:io';

import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_program.dart';

/// Store-compliance mode: the app shows only what it shipped with.
///
/// WHAT IT IS FOR. A store reviewer has none of the user's files and no way to
/// get any. Compliance mode is the state that proves the app works anyway --
/// everything on screen came in the bundle, and nothing else is reachable. The
/// same idea as Retro-C64's and Retro-Amiga's compliance modes, and
/// deliberately the same shape, because the same people review all three.
///
/// WHAT IT ACTUALLY CHANGES. The library scans a directory that holds nothing
/// but the bundled demo. That is the whole mechanism, and it is worth being
/// precise about why it is enough: the shelf is the only route into running
/// anything, so a library that lists only the demo is an app that can only run
/// the demo. Nothing is hidden or disabled -- there is simply nothing else in
/// the folder being read.
///
/// WHY IT IS NOT THE GAMES FOLDER. The obvious implementation -- scan the
/// demo's folder inside the user's games folder -- fails twice. The scanner
/// indexes programs only INSIDE a directory, so pointing it at the demo's own
/// folder finds nothing; and pointing it at the games folder lists the user's
/// titles, which is what the mode exists to exclude. So compliance mode reads
/// a directory of its own, under Application Support, where a user file cannot
/// arrive: the Files app publishes Documents, not this.
class ComplianceMode {
  ComplianceMode._();

  static const String _key = 'compliance_mode';
  static const String _asset = 'assets/demo/DEMO.COM';

  static Future<bool> isOn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  /// Turning it on stages the demo first, so the mode never lands on an empty
  /// shelf -- which would demonstrate the opposite of the point.
  static Future<void> set(bool on) async {
    if (on) await stageDemo();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, on);
  }

  /// The directory the library scans in compliance mode.
  static Future<String> rootPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'compliance');
  }

  /// Writes the demo into the compliance directory, as a folder containing the
  /// program -- the shape the scanner indexes.
  static Future<String> stageDemo() async {
    final root = await rootPath();
    final target =
        File(p.join(root, DemoProgram.folderName, DemoProgram.fileName));
    if (!target.existsSync()) {
      final ByteData data = await rootBundle.load(_asset);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return target.path;
  }
}
