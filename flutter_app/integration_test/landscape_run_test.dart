// Does the emulator render in LANDSCAPE?
//
// The screenshot run drives the app in the simulator's portrait shape and the
// emulator never produced a frame -- ninety seconds of "Waiting for first
// frame...". These are emulators of landscape machines, so the obvious
// question is whether the render surface only comes up when the view is wide.
// This answers it directly rather than by argument.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:retro_dosbox/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Finder byText(String s) => find.textContaining(s, findRichText: true);

  Future<void> hold(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds * 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  testWidgets('emulator renders in landscape', (tester) async {
    // Rotate the DEVICE, not the test's idea of it.
    //
    // Setting tester.view.physicalSize looks like rotation and is not: it
    // resizes the test view while the platform view stays put, and the capture
    // came back as the integration-test splash rather than the app. Asking the
    // engine for a landscape orientation is what actually turns the simulator.
    await SystemChrome.setPreferredOrientations(
        <DeviceOrientation>[DeviceOrientation.landscapeLeft]);
    addTearDown(() => SystemChrome.setPreferredOrientations(
        <DeviceOrientation>[]));

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));
    await hold(tester, 2);
    await binding.takeScreenshot('landscape-01-launched');

    // Straight to the shelf and into the bundled demo.
    for (final label in <String>['Continue', 'Skip for now']) {
      final f = byText(label);
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first, warnIfMissed: false);
        await tester.pumpAndSettle(const Duration(seconds: 2));
        break;
      }
    }
    await hold(tester, 2);
    await binding.takeScreenshot('landscape-02-library');

    final demo = byText('Demo');
    expect(demo, findsWidgets, reason: 'the bundled demo is not on the shelf');
    await tester.tap(demo.first, warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Wait for an actual frame, not a fixed count.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var stillWaiting = true;
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      stillWaiting = byText('Waiting for first frame').evaluate().isNotEmpty ||
          byText('Starting DOSBox').evaluate().isNotEmpty;
      if (!stillWaiting) break;
    }
    debugPrint('LANDSCAPE RESULT: still waiting for a frame = $stillWaiting');
    await binding.takeScreenshot('landscape-03-running');
    await hold(tester, 4);
  });
}
