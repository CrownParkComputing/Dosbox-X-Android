import 'package:dosboxx_launcher/data/game_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dosName', () {
    test('strips spaces and truncates to 8.3', () {
      expect(GameImport.dosName('boulder dash.exe'), 'BOULDERD.EXE');
      expect(GameImport.dosName('Commander Keen 4.EXE'), 'COMMANDE.EXE');
      expect(GameImport.dosName('a.b'), 'A.B');
    });

    test('keeps already-legal names (uppercased)', () {
      expect(GameImport.dosName('KEEN4E.EXE'), 'KEEN4E.EXE');
      expect(GameImport.dosName('readme.txt'), 'README.TXT');
    });

    test('extension truncates to 3, punctuation dropped', () {
      expect(GameImport.dosName('save (old).backup'), 'SAVEOLD.BAC');
      expect(GameImport.dosName("it's here!.txt"), 'ITSHERE.TXT');
    });

    test('dotfiles and empty stems survive', () {
      // A leading dot is not an extension separator in 8.3 terms.
      expect(GameImport.dosName('.hidden'), 'HIDDEN');
      expect(GameImport.dosName('   '), 'X');
    });

    test('no extension stays bare', () {
      expect(GameImport.dosName('My Long Directory Name'), 'MYLONGDI');
    });
  });

  group('dosPath', () {
    test('sanitises every segment and keeps directory identity', () {
      final Map<String, String> memo = <String, String>{};
      final Set<String> taken = <String>{};
      expect(GameImport.dosPath(['Game Data', 'level one.dat'], memo, taken),
          ['GAMEDATA', 'LEVELONE.DAT']);
      // Second file in the same original directory lands in the same place.
      expect(GameImport.dosPath(['Game Data', 'level two.dat'], memo, taken),
          ['GAMEDATA', 'LEVELTWO.DAT']);
    });

    test('colliding short names get a digit bumped in', () {
      final Map<String, String> memo = <String, String>{};
      final Set<String> taken = <String>{};
      expect(GameImport.dosPath(['HELLO WORLD.TXT'], memo, taken),
          ['HELLOWOR.TXT']);
      expect(GameImport.dosPath(['HELLOWORLD.TXT'], memo, taken),
          ['HELLOWO2.TXT']);
      // Underscores are DOS-legal, so this one never collided at all.
      expect(GameImport.dosPath(['HELLO_WORLD.TXT'], memo, taken),
          ['HELLO_WO.TXT']);
    });

    test('colliding directories stay distinct and stable', () {
      final Map<String, String> memo = <String, String>{};
      final Set<String> taken = <String>{};
      final List<String> a =
          GameImport.dosPath(['Long Dir Name A', 'f.txt'], memo, taken);
      final List<String> b =
          GameImport.dosPath(['Long Dir Name B', 'f.txt'], memo, taken);
      expect(a.first, isNot(b.first));
      // f.txt does not collide across the two now-distinct directories.
      expect(a.last, 'F.TXT');
      expect(b.last, 'F.TXT');
      // And the A directory keeps mapping to itself.
      expect(
          GameImport.dosPath(['Long Dir Name A', 'g.txt'], memo, taken).first,
          a.first);
    });
  });
}
