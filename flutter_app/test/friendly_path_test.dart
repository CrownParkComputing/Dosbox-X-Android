// A container path is not something a user can act on, and printing one put
// the build machine's directory layout -- account name included -- into an App
// Store screenshot.
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_dosbox/data/friendly_path.dart';

void main() {
  const docs = '/var/mobile/Containers/Data/Application/ABC-123/Documents';

  test('a path inside Documents becomes a Files-app location', () {
    expect(
      friendlyPath('$docs/Retro-DosBox/Retro-DosBox Demo/DEMO.COM', docs,
          deviceName: 'On My iPhone'),
      'On My iPhone › Retro-DosBox › Retro-DosBox '
      '› Retro-DosBox Demo › DEMO.COM',
    );
  });

  test('nothing of the container path survives', () {
    final out = friendlyPath('$docs/Retro-DosBox/A/B.COM', docs,
        deviceName: 'On My iPhone');
    expect(out, isNot(contains('Containers')));
    expect(out, isNot(contains('Application')));
    expect(out, isNot(contains('/var/')));
  });

  test('a simulator path leaks no account name', () {
    const simDocs = '/Volumes/Macintosh_HD/Users/someone/Library/Developer/'
        'CoreSimulator/Devices/592BE443/data/Containers/Data/Application/'
        '2186390C/Documents';
    final out = friendlyPath('$simDocs/Retro-DosBox/x.img', simDocs,
        deviceName: 'On My iPhone');
    expect(out, isNot(contains('someone')));
    expect(out, isNot(contains('CoreSimulator')));
  });

  test('a path outside Documents is left alone', () {
    expect(friendlyPath('/elsewhere/thing.img', docs), '/elsewhere/thing.img');
  });

  test('empty inputs are returned unchanged rather than decorated', () {
    expect(friendlyPath('', docs), '');
    expect(friendlyPath('/a/b', ''), '/a/b');
  });
}
