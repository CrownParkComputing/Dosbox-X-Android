// The disc in the drive: chosen before boot, or changed while running.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_dosbox/services/games_folder.dart';
import 'package:retro_dosbox/services/library_scanner.dart';
import 'package:retro_dosbox/data/game_entry.dart';
import 'package:retro_dosbox/ffi/stub_retrodosbox_core.dart';
import 'package:retro_dosbox/services/retrodosbox_conf_builder.dart';

String confFor(GameEntry entry, GameSettings settings) =>
    RetroDosboxConfBuilder.build(
      entry: entry,
      settings: settings,
      captureRoot: '/tmp/captures',
      windowed: false,
    );

void main() {
  const bootDisk = GameEntry(
    path: '/games/dosboot/Boot.vhd',
    kind: GameKind.bootImage,
    title: 'DOS boot disk',
  );

  group('the disc chosen before boot', () {
    test('is mounted as the first CD drive', () {
      final conf = confFor(
        bootDisk,
        const GameSettings(cdImage: '/games/discs/Game.iso'),
      );
      expect(conf, contains('imgmount d "/games/discs/Game.iso" -t iso'));
    });

    test('comes before discs found beside the title', () {
      // The chosen one is the deliberate one, so it gets the first letter.
      const entry = GameEntry(
        path: '/games/dosboot/Boot.vhd',
        kind: GameKind.bootImage,
        title: 'DOS boot disk',
        discs: <String>['/games/win98/Beside.iso'],
      );
      final conf = confFor(
        entry,
        const GameSettings(cdImage: '/games/discs/Chosen.iso'),
      );
      // The chosen disc takes the first drive letter; found discs follow.
      expect(conf, contains('imgmount d "/games/discs/Chosen.iso" -t iso'));
      expect(conf, contains('imgmount e "/games/win98/Beside.iso" -t iso'));
    });

    test('is not mounted twice when it is also beside the title', () {
      const entry = GameEntry(
        path: '/games/dosboot/Boot.vhd',
        kind: GameKind.bootImage,
        title: 'DOS boot disk',
        discs: <String>['/games/win98/Game.iso'],
      );
      final conf = confFor(
        entry,
        const GameSettings(cdImage: '/games/win98/Game.iso'),
      );
      expect('Game.iso'.allMatches(conf).length, 1);
    });

    test('no choice leaves whatever is beside the title', () {
      const entry = GameEntry(
        path: '/games/dosboot/Boot.vhd',
        kind: GameKind.bootImage,
        title: 'DOS boot disk',
        discs: <String>['/games/win98/Beside.iso'],
      );
      final conf = confFor(entry, const GameSettings());
      expect(conf, contains('imgmount d "/games/win98/Beside.iso" -t iso'));
    });

    test('survives a round trip through the settings store', () {
      const settings = GameSettings(cdImage: '/games/discs/Game.iso');
      final restored = GameSettings.fromJson(settings.toJson());
      expect(restored.cdImage, '/games/discs/Game.iso');
    });
  });

  group('changing the disc while running', () {
    test('reaches the core', () {
      final core = StubRetroDosboxCore()..start('/tmp/dosbox-x.conf');
      core.cdInsert('/games/discs/Disc2.iso');
      expect(core.insertedDiscs, <String>['/games/discs/Disc2.iso']);
    });

    test('an empty path is an eject, not an error', () {
      final core = StubRetroDosboxCore()..start('/tmp/dosbox-x.conf');
      core.cdInsert('');
      expect(core.insertedDiscs, <String>['']);
    });

    test('is refused when nothing is running', () {
      // A disc handed to a machine that is not running would be silently
      // lost, and the caller should be able to tell.
      final core = StubRetroDosboxCore();
      expect(core.cdInsert('/games/discs/Disc2.iso'), isNot(0));
    });
  });

  group('the CD shelf', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cds'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('is not scanned as a library of titles', () async {
      // A disc is something you put IN a machine, not something you launch.
      // Listing the shelf as titles would bury the games under every ISO.
      final cds = Directory(p.join(tmp.path, GamesFolder.cdFolderName))
        ..createSync();
      File(p.join(cds.path, 'Game.iso')).writeAsStringSync('x');
      final game = Directory(p.join(tmp.path, 'Doom'))..createSync();
      File(p.join(game.path, 'DOOM.EXE')).writeAsStringSync('x');

      final result = await LibraryScanner.scan(tmp.path);
      expect(result.entries.map((e) => e.title), <String>['Doom']);
    });

    test('browses recursively, so it can be organised', () async {
      final cds = Directory(p.join(tmp.path, 'sub'))..createSync();
      File(p.join(tmp.path, 'Top.iso')).writeAsStringSync('x');
      File(p.join(cds.path, 'Nested.iso')).writeAsStringSync('x');

      final found = await LibraryScanner.findDiscImages(tmp.path);
      expect(found.map((f) => p.basename(f)).toList()..sort(),
          <String>['Nested.iso', 'Top.iso']);
    });

    test('labels a disc by its place on the shelf, not just its name',
        () {
      // Two discs called Disc1.iso in different folders have to be
      // tellable apart in the picker.
      expect(
        GamesFolder.discLabel('/games/CDs/Quake/Disc1.iso', '/games/CDs'),
        p.join('Quake', 'Disc1.iso'),
      );
    });

    test('a disc from outside the shelf still gets a readable label', () {
      expect(
        GamesFolder.discLabel('/elsewhere/Beside.iso', '/games/CDs'),
        'Beside.iso',
      );
    });
  });
}
