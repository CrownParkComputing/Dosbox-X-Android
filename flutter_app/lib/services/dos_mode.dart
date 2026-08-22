import 'dart:io';

import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which DOS the emulator runs.
///
/// Both are free software and both ship with the app; neither is MS-DOS, which
/// is Microsoft's and is not here.
enum DosMode {
  /// DOSBox-X's own DOS. Not a boot at all -- the emulator provides the DOS
  /// services itself and mounts the games folder as C:. Faster to start, and
  /// what almost everything wants.
  builtIn,

  /// A real FreeDOS 1.3, booted from the bundled floppy image. Slower, and the
  /// games folder arrives as a second drive rather than C: -- but it is a
  /// genuine DOS underneath, which is what a few programs insist on.
  freeDos,
}

/// The DOS the emulator boots, and the bundled FreeDOS image behind it.
class DosModeService {
  DosModeService._();

  static const String _key = 'dos_mode';
  static const String imageName = 'FD13BOOT.img';
  static const String _asset = 'assets/freedos/FD13BOOT.img';

  /// The mode in force. Built-in unless the user has chosen otherwise: it
  /// needs no boot, so it is the one that works on the widest set of hardware
  /// and starts fastest.
  static Future<DosMode> current() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) == 'freedos' ? DosMode.freeDos : DosMode.builtIn;
  }

  static Future<void> set(DosMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode == DosMode.freeDos ? 'freedos' : 'builtin');
  }

  /// Where the boot image lives once extracted.
  ///
  /// It has to be a real file, not an asset: the emulator mounts it through
  /// IMGMOUNT, which opens a path on disk and knows nothing about Flutter's
  /// asset bundle.
  static Future<String> imagePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'freedos', imageName);
  }

  /// Extracts the boot image if it is not already there. Returns its path.
  static Future<String> ensureImage() async {
    final path = await imagePath();
    final file = File(path);
    if (!file.existsSync()) {
      final ByteData data = await rootBundle.load(_asset);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return path;
  }

  /// The commands that boot FreeDOS, in order.
  ///
  /// Split out from the sending so it can be asserted in a test: the ordering
  /// matters and is easy to get subtly wrong. IMGMOUNT attaches the image as
  /// drive A:, and BOOT hands the machine to it -- after which DOSBox-X's own
  /// DOS is gone and the floppy's kernel is in charge, which is the whole
  /// point of the mode.
  static List<String> bootCommands(String imagePath) => <String>[
        'IMGMOUNT A "$imagePath" -t floppy',
        'BOOT A:',
      ];
}
