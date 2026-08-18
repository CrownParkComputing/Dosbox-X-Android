// Widget and unit tests that run with no native core, no device and no DOS
// game files -- which is the whole reason DosboxCore is an interface and
// StubDosboxCore exists.
import 'package:dosbox_multiplatform/data/dos_scancodes.dart';
import 'package:dosbox_multiplatform/data/game_entry.dart';
import 'package:dosbox_multiplatform/ffi/dosbox_core.dart';
import 'package:dosbox_multiplatform/ffi/stub_dosbox_core.dart';
import 'package:dosbox_multiplatform/screens/library_grid.dart';
import 'package:dosbox_multiplatform/services/dos_conf_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StubDosboxCore', () {
    test('reports not running until started', () {
      final core = StubDosboxCore();
      expect(core.isRunning, isFalse);
      expect(core.getFramebuffer(), isNull);
      expect(core.runningProgram, isNull);
    });

    test('produces frames once started', () {
      final core = StubDosboxCore();
      expect(core.start('/tmp/test.conf'), DosboxResult.ok);
      expect(core.isRunning, isTrue);

      final frame = core.getFramebuffer();
      expect(frame, isNotNull);
      expect(frame!.width, 320);
      expect(frame.height, 200);
      expect(frame.pixels.length, 320 * 200);
      // Fully opaque: a bug that dropped the alpha channel would otherwise
      // show as an invisible picture rather than a test failure.
      expect(frame.pixels.first & 0xFF000000, 0xFF000000);
    });

    test('refuses a second start, matching the real core', () {
      final core = StubDosboxCore();
      expect(core.start('/tmp/a.conf'), DosboxResult.ok);
      expect(core.start('/tmp/b.conf'), DosboxResult.alreadyStarted);
    });

    test('advances the frame counter only while unpaused', () {
      final core = StubDosboxCore();
      core.start('/tmp/test.conf');
      core.getFramebuffer();
      final before = core.frameCounter;
      core.setPaused(true);
      core.getFramebuffer();
      expect(core.frameCounter, before);
      core.setPaused(false);
      core.getFramebuffer();
      expect(core.frameCounter, greaterThan(before));
    });
  });

  group('DosConfBuilder', () {
    GameEntry folderEntry({
      String title = 'DOOM',
      List<String> launchers = const ['/games/DOOM/DOOM.EXE'],
      List<String> discs = const [],
    }) {
      return GameEntry(
        path: '/games/$title',
        kind: GameKind.dosFolder,
        title: title,
        launchers: launchers,
        discs: discs,
      );
    }

    test('mounts C: and runs the launcher', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(),
        settings: const GameSettings(),
      );
      expect(conf, contains('[autoexec]'));
      expect(conf, contains('mount c "/games/DOOM"'));
      expect(conf, contains('c:'));
      expect(conf, contains('DOOM.EXE'));
    });

    test('keeps memsize below the DOS/4GW 64MB limit', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(),
        settings: const GameSettings(),
      );
      final match = RegExp(r'memsize=(\d+)').firstMatch(conf);
      expect(match, isNotNull);
      expect(int.parse(match!.group(1)!), lessThan(64));
    });

    test('prefers the game over the order form and dealer list', () {
      // Straight from a real device run: Commander Keen 1 shareware ships
      // CATALOG.EXE, DEALERS.EXE and KEEN1.EXE. Alphabetically DEALERS wins,
      // and the iPad duly launched Apogee's worldwide dealer list.
      final entry = GameEntry(
        path: '/games/CKeen1',
        kind: GameKind.dosFolder,
        title: 'CKeen1',
        launchers: const [
          '/games/CKeen1/CATALOG.EXE',
          '/games/CKeen1/DEALERS.EXE',
          '/games/CKeen1/KEEN1.EXE',
        ],
      );
      expect(entry.preferredLauncher, '/games/CKeen1/KEEN1.EXE');
    });

    test('falls back to a non-installer when nothing matches the folder', () {
      final entry = GameEntry(
        path: '/games/Whatever',
        kind: GameKind.dosFolder,
        title: 'Whatever',
        launchers: const [
          '/games/Whatever/INSTALL.EXE',
          '/games/Whatever/PLAY.EXE',
        ],
      );
      expect(entry.preferredLauncher, '/games/Whatever/PLAY.EXE');
    });

    test('still launches something when every candidate looks like packaging',
        () {
      // Better to run the installer than to refuse to launch at all.
      final entry = GameEntry(
        path: '/games/Odd',
        kind: GameKind.dosFolder,
        title: 'Odd',
        launchers: const ['/games/Odd/SETUP.EXE'],
      );
      expect(entry.preferredLauncher, '/games/Odd/SETUP.EXE');
    });

    test('selects the offscreen output the bridge actually hooks', () {
      // The bug this guards is silent, which is why it is worth a test: the
      // bridge hooks OUTPUT_GAMELINK_Transfer, and the conf is the ONLY channel
      // that selects it. With any other output -- or with output=gamelink but
      // no `gamelink master` -- OUTPUT_GAMELINK_Select() quietly falls back to
      // output=surface. The engine then boots and renders perfectly into a
      // window surface nothing reads, so the app shows a black screen with no
      // error anywhere. Both lines are load-bearing.
      final conf = DosConfBuilder.build(
        entry: GameEntry(
          path: '/games/Keen1',
          kind: GameKind.dosFolder,
          title: 'Keen1',
        ),
        settings: const GameSettings(),
      );
      expect(conf, contains('output=gamelink'));
      expect(conf, contains('gamelink master=true'));
    });

    test('mounts the parent for the IndyCar DOS4G_GET_APPPATH workaround', () {
      // The bug this guards: run from the C: root, IndyCar asks DOS/4GW for
      // its own path, gets an empty string, and dies.
      final conf = DosConfBuilder.build(
        entry: GameEntry(
          path: '/games/IndyCar2',
          kind: GameKind.dosFolder,
          title: 'IndyCar2',
        ),
        settings: const GameSettings(),
      );
      expect(conf, contains('mount c "/games"'));
      expect(conf, contains(r'cd "IndyCar2"'));
    });

    test('gives setup programs a fixed clock, not auto', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(launchers: const ['/games/X/SETUP.EXE']),
        settings: const GameSettings(),
        launcher: '/games/X/SETUP.EXE',
      );
      expect(conf, contains('cycles=fixed 20000'));
    });

    test("Screamer's setup gets its own lower clock and vesa_nolfb", () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(title: 'Screamer'),
        settings: const GameSettings(),
        launcher: '/games/Screamer/SETUP.EXE',
      );
      expect(conf, contains('cycles=fixed 12000'));
      expect(conf, contains('machine=vesa_nolfb'));
    });

    test('an explicit preset overrides the heuristics', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(),
        settings: const GameSettings(preset: CpuPreset.era80s),
        launcher: '/games/DOOM/SETUP.EXE',
      );
      expect(conf, contains('cycles=3000'));
      expect(conf, contains('machine=cga'));
      expect(conf, contains('core=normal'));
    });

    test('3dfx executables enable the Voodoo and a bigger audio buffer', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(launchers: const ['/games/X/GAME3DFX.EXE']),
        settings: const GameSettings(),
        launcher: '/games/X/GAME3DFX.EXE',
      );
      expect(conf, contains('voodoo_card=software'));
      expect(conf, contains('blocksize=2048'));
    });

    test('groups multiple discs onto one drive letter as a swap set', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(
          discs: const ['/games/DOOM/cd1.iso', '/games/DOOM/cd2.iso'],
        ),
        settings: const GameSettings(),
      );
      expect(
        conf,
        contains('imgmount d "/games/DOOM/cd1.iso" "/games/DOOM/cd2.iso" '
            '-t iso'),
      );
    });

    test('separates raw .bin tracks from .iso images', () {
      // Different -t handling, so they must not share a mount command.
      final conf = DosConfBuilder.build(
        entry: folderEntry(
          discs: const ['/games/X/a.iso', '/games/X/b.bin'],
        ),
        settings: const GameSettings(),
      );
      expect(conf, contains('imgmount d "/games/X/a.iso" -t iso'));
      expect(conf, contains('imgmount e "/games/X/b.bin" -t iso'));
    });

    test('boot images boot rather than mounting C:', () {
      final conf = DosConfBuilder.build(
        entry: const GameEntry(
          path: '/games/win98.img',
          kind: GameKind.bootImage,
          title: 'Windows 98',
        ),
        settings: const GameSettings(),
      );
      expect(conf, contains('imgmount c "/games/win98.img" -t hdd -fs none'));
      expect(conf, contains('boot -l c'));
      // No plain `mount c` -- the image IS the disk, so there is no host
      // directory to mount. Anchored to the line start because a substring
      // check would match the `imgmount c` above.
      expect(conf, isNot(matches(RegExp(r'^mount c ', multiLine: true))));
    });

    test('falls back to a prompt with a listing when nothing is runnable', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(launchers: const []),
        settings: const GameSettings(),
      );
      expect(conf, contains('dir /w'));
      expect(conf, contains('echo Type the EXE or BAT name to run the game.'));
    });

    test('disabling the joystick emits joysticktype=none, not an omission', () {
      final conf = DosConfBuilder.build(
        entry: folderEntry(),
        settings: const GameSettings(joystick: false),
      );
      expect(conf, contains('joysticktype=none'));
    });

    test('quotes paths containing spaces', () {
      final conf = DosConfBuilder.build(
        entry: GameEntry(
          path: '/storage/emulated/0/My Games/Alone in the Dark',
          kind: GameKind.dosFolder,
          title: 'Alone in the Dark',
        ),
        settings: const GameSettings(),
      );
      expect(
        conf,
        contains('mount c "/storage/emulated/0/My Games/Alone in the Dark"'),
      );
    });
  });

  group('GameEntry', () {
    test('prefers a .bat launcher over an .exe', () {
      // Shipped batch files set up the environment the bare exe assumes.
      const entry = GameEntry(
        path: '/games/X',
        kind: GameKind.dosFolder,
        title: 'X',
        launchers: ['/games/X/GAME.EXE', '/games/X/PLAY.BAT'],
      );
      expect(entry.preferredLauncher, '/games/X/PLAY.BAT');
    });

    test('slug is stable and filesystem safe', () {
      const entry = GameEntry(
        path: '/games/Alone in the Dark!',
        kind: GameKind.dosFolder,
        title: 'Alone in the Dark!',
      );
      expect(entry.slug, 'alone_in_the_dark_');
      expect(entry.slug, matches(RegExp(r'^[a-z0-9_]+$')));
    });

    test('archives are launchable through ZipRunner', () {
      const entry = GameEntry(
        path: '/games/x.zip',
        kind: GameKind.archive,
        title: 'x',
      );
      expect(entry.isLaunchable, isTrue);
    });
  });

  group('DosKeyCatalogue', () {
    test('every catalogue key resolves back to itself', () {
      for (final group in DosKeyCatalogue.groups.values) {
        for (final key in group) {
          expect(DosKeyCatalogue.byScancode(key.scancode), isNotNull);
        }
      }
    });

    test('labels an unknown scancode instead of returning blank', () {
      expect(DosKeyCatalogue.labelFor(9999), 'Key 9999');
    });

    test('keypad keys are distinct from the number row', () {
      // A DOS flight sim steers with the keypad; collapsing the two would make
      // it uncontrollable.
      expect(DosScancode.kp1, isNot(DosScancode.n1));
      expect(DosScancode.kp0, isNot(DosScancode.n0));
    });
  });

  group('LibraryGrid', () {
    const entries = [
      GameEntry(
        path: '/games/DOOM',
        kind: GameKind.dosFolder,
        title: 'DOOM',
        launchers: ['/games/DOOM/DOOM.EXE'],
      ),
      GameEntry(
        path: '/games/quake.iso',
        kind: GameKind.discImage,
        title: 'Quake',
      ),
    ];

    testWidgets('lists titles and reports the count', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LibraryGrid(entries: entries, onLaunch: _noop),
        ),
      ));
      expect(find.text('DOOM'), findsOneWidget);
      expect(find.text('Quake'), findsOneWidget);
      expect(find.text('2 titles'), findsOneWidget);
    });

    testWidgets('launches the tapped title', (tester) async {
      final launched = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LibraryGrid(
            entries: entries,
            onLaunch: (e) => launched.add(e.title),
          ),
        ),
      ));
      await tester.tap(find.text('DOOM'));
      await tester.pump();
      expect(launched, ['DOOM']);
    });

    testWidgets('search narrows the list', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LibraryGrid(entries: entries, onLaunch: _noop),
        ),
      ));
      await tester.enterText(find.byType(TextField), 'quake');
      await tester.pump();
      expect(find.text('DOOM'), findsNothing);
      expect(find.text('Quake'), findsOneWidget);
      expect(find.text('1 of 2 titles'), findsOneWidget);
    });

    testWidgets('distinguishes an empty library from an empty filter',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LibraryGrid(entries: [], onLaunch: _noop),
        ),
      ));
      expect(find.text('No games found.'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LibraryGrid(entries: entries, onLaunch: _noop),
        ),
      ));
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump();
      expect(find.text('No titles match this search.'), findsOneWidget);
    });

    testWidgets('surfaces unreadable paths rather than hiding them',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LibraryGrid(
            entries: entries,
            unreadable: ['/games/locked'],
            onLaunch: _noop,
          ),
        ),
      ));
      expect(find.textContaining('1 unreadable'), findsOneWidget);
    });
  });
}

void _noop(GameEntry entry) {}
