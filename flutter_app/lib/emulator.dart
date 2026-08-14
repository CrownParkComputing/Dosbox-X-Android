import 'dart:io';

import 'package:flutter/services.dart';

import 'data/conf_generator.dart';
import 'data/conf_overrides.dart';
import 'data/dos_settings.dart';

/// The one road from Flutter into the emulator.
///
/// Same contract the Java launcher spoke: write dosbox-x.conf where the
/// core reads it, start the SDL activity in its own :emu process. Quitting
/// a game kills that process; every game starts fresh - which is why the
/// multi-run bugs the Amiga launcher fought cannot happen here.
class Emulator {
  static const MethodChannel _channel = MethodChannel('dosboxx/emulator');

  static Future<String> gamesDir() async =>
      await _channel.invokeMethod<String>('gamesDir') ?? '';

  static Future<void> launch(DosSettings settings,
      [ConfOverrides? overrides]) async {
    final String confPath =
        await _channel.invokeMethod<String>('confPath') ?? '';
    if (confPath.isEmpty) {
      throw Exception('The emulator did not say where its conf lives.');
    }
    File(confPath)
        .writeAsStringSync(ConfGenerator.generate(settings, overrides));
    await _channel.invokeMethod<bool>('launch');
  }
}
