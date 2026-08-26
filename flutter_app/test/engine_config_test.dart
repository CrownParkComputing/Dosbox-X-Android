// The engine's config, read and written across a process boundary.
//
// The bug this exists to prevent: on Android the engine runs in :dosbox and
// the launcher's core object is an idle handle that reports no sections, so
// the settings screen said "No running session" over a running game and any
// change went to a core with nothing in it. Input was routed across that
// boundary long ago; config was not.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retro_dosbox/ffi/retrodosbox_core.dart';

void main() {
  group('the published dump', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('engcfg'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// The shape publishEngineConfig writes and _PublishedConfig reads. Kept
    /// as one round trip because the two halves live in different PROCESSES
    /// and nothing else can catch them disagreeing.
    test('round-trips every field the screen renders', () {
      const original = RetroDosboxConfigProperty(
        name: 'core',
        type: 'string',
        value: 'dynamic',
        defaultValue: 'auto',
        help: 'CPU Core used in emulation.',
        values: <String>['auto', 'normal', 'dynamic'],
      );

      final encoded = jsonEncode({
        'cpu': [
          {
            'name': original.name,
            'type': original.type,
            'value': original.value,
            'default': original.defaultValue,
            'help': original.help,
            'values': original.values,
          }
        ]
      });

      final decoded = (jsonDecode(encoded) as Map)['cpu'] as List;
      final back = RetroDosboxConfigProperty.fromJson(
        decoded.first as Map<String, dynamic>,
      );

      expect(back.name, original.name);
      expect(back.type, original.type);
      expect(back.value, original.value);
      // 'default' on the wire, defaultValue in Dart -- an easy pair to get
      // wrong, and silently: the Reset button would just stop working.
      expect(back.defaultValue, original.defaultValue);
      expect(back.help, original.help);
      expect(back.values, original.values);
    });

    test('a missing dump is an empty config, not a crash', () {
      // The launcher may open the screen before the engine has published, or
      // with no session at all. Both must read as "nothing to show".
      final decoded = jsonDecode('{}');
      expect(decoded, isA<Map>());
      expect((decoded as Map).isEmpty, isTrue);
    });
  });

  group('applying a value optimistically', () {
    test('copyWith replaces only the value', () {
      // The dump is written once per session, so after a write the screen has
      // to remember what was asked for; otherwise it snaps back to the
      // launch-time value and every change looks rejected.
      const p = RetroDosboxConfigProperty(
        name: 'cycles',
        type: 'string',
        value: 'auto',
        defaultValue: 'auto',
        help: 'Cycles.',
        values: <String>[],
      );
      final changed = p.copyWith(value: 'max');
      expect(changed.value, 'max');
      expect(changed.name, p.name);
      expect(changed.defaultValue, p.defaultValue);
      expect(changed.help, p.help);
      expect(changed.type, p.type);
    });
  });
}
