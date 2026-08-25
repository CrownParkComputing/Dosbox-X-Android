// Why does the emulator never produce a frame?
//
// The panel says "Waiting for first frame..." forever, which is all it can say:
// it polls frameCounter and nothing else. dosbox_core_start returns OK as soon
// as the mainloop THREAD is created, so success there says nothing about
// whether dosbox_x_main survived. This asks the core directly, once a second,
// so the difference between "still booting", "running but not drawing" and
// "the engine died" is visible instead of inferred.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:retro_dosbox/main.dart' as app;
import 'package:retro_dosbox/ffi/retrodosbox_core.dart';
import 'package:retro_dosbox/screens/workbench_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Finder byText(String s) => find.textContaining(s, findRichText: true);

  testWidgets('reports what the engine is doing', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // The wizard types its text out on a timer, so the frame that settles has
    // no buttons on it yet. Wait for the controls in real time.
    final wizDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (byText('Store Compliance').evaluate().isEmpty &&
        DateTime.now().isBefore(wizDeadline)) {
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    for (final label in <String>['Continue', 'Skip for now']) {
      final text = byText(label);
      if (text.evaluate().isEmpty) continue;
      // The button, not the sentence that names it.
      Finder target = text;
      for (final t in <Type>[TextButton, OutlinedButton, ElevatedButton, InkWell]) {
        final f = find.ancestor(of: text, matching: find.byType(t));
        if (f.evaluate().isNotEmpty) { target = f; break; }
      }
      await tester.tap(target.first, warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      break;
    }

    // The shelf scans off the main isolate, so wait in real time rather than
    // assuming the frame that settled is the one with the demo on it.
    var demo = byText('Demo');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (demo.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      demo = byText('Demo');
    }
    if (demo.evaluate().isEmpty) {
      for (final e in find.byType(Text).evaluate()) {
        final t = (e.widget as Text).data;
        if (t != null && t.trim().isNotEmpty && t.length < 60) {
          debugPrint('PROBE on-screen| $t');
        }
      }
      fail('the bundled demo never appeared on the shelf');
    }
    await tester.tap(demo.first, warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The core is owned by main() and handed to the workbench, so the widget
    // is where a test can reach the very instance the app is using.
    RetroDosboxCore? core;
    final wb = find.byType(WorkbenchScreen);
    if (wb.evaluate().isNotEmpty) {
      core = tester.widget<WorkbenchScreen>(wb).core;
      debugPrint('PROBE: core is ${core.runtimeType}');
    } else {
      debugPrint('PROBE: no WorkbenchScreen on screen');
    }

    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (core != null) {
        debugPrint('PROBE t=${i}s running=${core.isRunning} '
            'frames=${core.frameCounter} fps=${core.fps} '
            'status=${core.statusLine}');
      }
    }
  });
}
