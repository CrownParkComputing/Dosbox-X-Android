// This app emulates a DOS machine, and only a DOS machine.
//
// Windows 95/98 support was built, proven to boot on the device, and then
// removed: on ARM the only fast CPU core is the one DOSBox-X documents as
// incompatible with Windows 95 and later, so a Windows guest is stuck on the
// interpreter, and every 3D title of that era becomes a black screen with
// healthy audio. These tests keep the Windows machine profile from creeping
// back in, and keep the app declining such images out loud instead of booting
// them into a hang.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_dosbox/data/game_entry.dart';
import 'package:retro_dosbox/services/library_scanner.dart';
import 'package:retro_dosbox/services/retrodosbox_conf_builder.dart';

/// A dynamic VHD describing a disk of [virtualBytes] while occupying almost
/// nothing -- the shape every pre-built Windows image ships as, and the one
/// that defeats a naive file-length check.
File writeDynamicVhd(Directory dir, String name, int virtualBytes) {
  final footer = Uint8List(512);
  final view = ByteData.sublistView(footer);
  const cookie = <int>[0x63, 0x6F, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x78];
  footer.setRange(0, cookie.length, cookie);
  view.setUint64(0x10, 512, Endian.big);
  view.setUint64(0x30, virtualBytes, Endian.big);
  view.setUint32(0x3C, 3, Endian.big);
  return File(p.join(dir.path, name))..writeAsBytesSync(footer);
}

String confFor(GameEntry entry) => RetroDosboxConfBuilder.build(
      entry: entry,
      settings: const GameSettings(),
      captureRoot: '/tmp/captures',
      windowed: false,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dos_only'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('the machine is a DOS machine', () {
    test('no Windows profile survives in the generated conf', () async {
      final vhd = writeDynamicVhd(tmp, 'boot.vhd', 40 * 1024 * 1024);
      final entry = (await LibraryScanner.classify(vhd.path))!;
      final conf = confFor(entry);

      // Every one of these existed only to make Windows 9x work.
      for (final gone in <String>[
        '[ide, primary]',
        '[ide, secondary]',
        '[fdc, primary]',
        'int13fakeio',
        'int13fakev86io',
        'cputype=pentium_mmx',
        'memsize=64',
        'sbtype=sb16',
        'hard drive data rate limit',
        '-ide 1m',
        '-ide 2m',
      ]) {
        expect(conf, isNot(contains(gone)), reason: '"$gone" came back');
      }
    });

    test('the DOS defaults are the ones that survive', () async {
      final vhd = writeDynamicVhd(tmp, 'boot.vhd', 40 * 1024 * 1024);
      final entry = (await LibraryScanner.classify(vhd.path))!;
      final conf = confFor(entry);
      // 32MB is the DOS/4GW workaround; sbpro2 is 8-bit DMA, which plays
      // digital sound where sb16's 16-bit DMA goes silent.
      expect(conf, contains('memsize=32'));
      expect(conf, contains('cputype=pentium'));
      expect(conf, contains('sbtype=sbpro2'));
      expect(conf, contains('core=dynamic'),
          reason: 'DOS keeps the fast core; that is the whole point');
    });

    test('a DOS boot image still boots, by BIOS drive number', () async {
      // `-fs none` attaches a raw BIOS disk and imgmount rejects a drive
      // LETTER there outright, leaving a DOSBox prompt and "BOOT: Failed to
      // open disk image". 2 is hda.
      final vhd = writeDynamicVhd(tmp, 'boot.vhd', 40 * 1024 * 1024);
      final entry = (await LibraryScanner.classify(vhd.path))!;
      final conf = confFor(entry);
      expect(conf, contains('imgmount 2 "${vhd.path}" -t hdd -fs none'));
      expect(conf, contains('boot -l c'));
    });

    test('disk images are not locked', () async {
      // fopen_lock() flocks the image and, if the lock fails, closes the file
      // and reports failure. FUSE-backed storage -- any Android SD card --
      // does not support flock, so a perfectly good image reports "Could not
      // open the specified VHD file".
      final vhd = writeDynamicVhd(tmp, 'boot.vhd', 40 * 1024 * 1024);
      final entry = (await LibraryScanner.classify(vhd.path))!;
      expect(confFor(entry), contains('locking disk image mount=false'));
    });
  });

  group('an installed Windows is declined, not attempted', () {
    test('a big disk image is recognised as Windows', () async {
      final vhd = writeDynamicVhd(tmp, 'win98.vhd', 2 * 1024 * 1024 * 1024);
      final entry = (await LibraryScanner.classify(vhd.path))!;
      expect(RetroDosboxConfBuilder.looksLikeInstalledWindows(entry), isTrue);
    });

    test('a DOS boot disk is not', () async {
      // Tens of megabytes is a DOS boot disk; the smallest usable Windows 98
      // install is several hundred. Nothing real sits near the line.
      final vhd = writeDynamicVhd(tmp, 'dos.vhd', 40 * 1024 * 1024);
      final entry = (await LibraryScanner.classify(vhd.path))!;
      expect(RetroDosboxConfBuilder.looksLikeInstalledWindows(entry), isFalse);
    });

    test('the size read is the disk, not the file', () async {
      // A dynamic VHD holding a 20GB Windows is a few hundred bytes on disk
      // until it is filled. Going by file length would call every pre-built
      // Windows image a tiny DOS disk and boot it into the hang.
      final vhd = writeDynamicVhd(tmp, 'win98.vhd', 20 * 1024 * 1024 * 1024);
      expect(vhd.lengthSync(), lessThan(1024));
      final entry = (await LibraryScanner.classify(vhd.path))!;
      expect(RetroDosboxConfBuilder.looksLikeInstalledWindows(entry), isTrue);
    });

    test('a DOS folder is never mistaken for one', () {
      const folder = GameEntry(
        path: '/games/doom',
        kind: GameKind.dosFolder,
        title: 'doom',
      );
      expect(
        RetroDosboxConfBuilder.looksLikeInstalledWindows(folder),
        isFalse,
      );
    });
  });
}
