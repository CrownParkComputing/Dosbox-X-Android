import 'dos_settings.dart';

/// Serialises a [DosSettings] into the dosbox-x.conf the core reads.
///
/// Kept free of dart:io so the exact text is unit-testable: a conf that
/// drifts from what the core expects fails on a phone screen a long way
/// from this file.
class ConfGenerator {
  const ConfGenerator._();

  static String generate(DosSettings s) {
    final StringBuffer b = StringBuffer()
      ..writeln('# Written by the launcher. Edits are overwritten on launch.')
      ..writeln('[sdl]')
      ..writeln('fullscreen=true')
      ..writeln('autolock=true')
      ..writeln()
      ..writeln('[dosbox]')
      ..writeln('title=DOSBox-X')
      ..writeln('memsize=${s.machine.memsizeMb}')
      ..writeln()
      ..writeln('[cpu]')
      ..writeln('core=normal')
      ..writeln('cycles=${s.machine.cycles}')
      ..writeln()
      ..writeln('[sblaster]')
      ..writeln('sbtype=${s.soundBlaster ? 'sb16' : 'none'}')
      ..writeln()
      ..writeln('[gus]')
      ..writeln('gus=${s.gus}')
      ..writeln()
      ..writeln('[autoexec]');
    if (s.mountPath.isNotEmpty) {
      b
        ..writeln('mount c "${s.mountPath}"')
        ..writeln('c:');
    }
    for (final String line in s.autoexec.split('\n')) {
      if (line.trim().isNotEmpty) b.writeln(line.trim());
    }
    return b.toString();
  }
}
