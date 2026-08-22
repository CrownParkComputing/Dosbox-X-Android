// Installs the app's FreeDOS homebrew image into private app support storage.
//
// Keeping it separate from the user's games folder matters: a compliance
// demo must not add files to, inspect, or depend on the user's collection.
// The returned GameEntry boots through exactly the same DOSBox-X path as every
// other boot image, so it is evidence of a working emulator rather than a
// Flutter animation made to resemble one.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/game_entry.dart';

class DemoProgramInstallation {
  final Directory directory;
  final GameEntry entry;
  final List<String> files;

  const DemoProgramInstallation({
    required this.directory,
    required this.entry,
    required this.files,
  });
}

class DemoProgramService {
  DemoProgramService._();

  static const String title = 'Retro-DosBox Homebrew Demo';
  static const String imageName = 'FREEDOS.IMG';
  static const String executableName = 'RETRODEM.COM';
  static const String _assetPrefix = 'assets/demo/';
  static const List<String> bundledFiles = <String>[
    imageName,
    executableName,
    'retro_demo.S',
    'README.txt',
    'FREEDOS.txt',
    'LICENSE.txt',
    'GPL-2.0.txt',
  ];

  /// Writes the bundled demo to a private, deterministic directory.
  ///
  /// [parent] is a test seam. Production callers omit it and use application
  /// support; tests can supply a temporary directory without mocking plugins.
  static Future<DemoProgramInstallation> prepare({Directory? parent}) async {
    final support = parent ?? await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'compliance-demo'));
    await directory.create(recursive: true);

    for (final name in bundledFiles) {
      final data = await rootBundle.load('$_assetPrefix$name');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await _writeIfChanged(File(p.join(directory.path, name)), bytes);
    }

    final image = p.join(directory.path, imageName);
    return DemoProgramInstallation(
      directory: directory,
      files: bundledFiles,
      entry: GameEntry(path: image, kind: GameKind.floppyImage, title: title),
    );
  }

  static Future<void> _writeIfChanged(File file, Uint8List bytes) async {
    if (await file.exists()) {
      final current = await file.readAsBytes();
      if (_sameBytes(current, bytes)) return;
    }
    await file.writeAsBytes(bytes, flush: true);
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
