import 'dart:io';

import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;

import 'games_folder.dart';

/// The bundled demo, installed into the games folder so there is something to
/// run on a fresh install.
///
/// WHY THIS EXISTS. The app ships no games, and unlike the C64 and Amiga front
/// ends it ships no ROM either -- it does not need one, because DOSBox-X
/// carries its own DOS. So a fresh install boots to a working C:\> prompt and
/// an empty shelf, which demonstrates nothing: a reviewer with no DOS games of
/// their own has no way to see the emulator run at all.
///
/// DEMO.COM is ours (flutter_app/tool/make_demo_com.py builds it), for the same
/// reason the C64's demo.prg is: every DOS program that could serve here is
/// somebody's.
class DemoProgram {
  DemoProgram._();

  static const String fileName = 'DEMO.COM';
  static const String _asset = 'assets/demo/DEMO.COM';

  /// The demo is a FOLDER containing the program, not a loose file.
  ///
  /// That is what the library scanner recognises. At the top level of the
  /// games folder it indexes disc images and archives only -- .exe/.com/.bat
  /// count only INSIDE a directory, which is the shape a DOS game actually
  /// has and exactly what the empty shelf tells the user to provide. A loose
  /// DEMO.COM installs correctly, is mounted correctly, and never appears.
  ///
  /// The folder name is the title on the shelf.
  static const String folderName = 'Retro-DosBox Demo';

  /// Where it lands: inside the folder DOSBox-X mounts as C:, so the demo is
  /// on the shelf beside whatever the user adds later.
  static Future<String> installedPath() async =>
      p.join(await GamesFolder.resolve(), folderName, fileName);

  /// Writes the demo into the games folder if it is not already there.
  ///
  /// Returns true if it wrote one. Deliberately does NOT overwrite an existing
  /// file: the folder is the user's, and a demo that reappears after being
  /// deleted -- or that overwrites something they put there under the same
  /// name -- is the app helping itself to their space.
  static Future<bool> install() async {
    final File target = File(await installedPath());
    if (target.existsSync()) return false;
    final ByteData data = await rootBundle.load(_asset);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return true;
  }
}
