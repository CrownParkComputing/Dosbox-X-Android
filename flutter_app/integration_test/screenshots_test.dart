// Drives the app through the screens the App Store listing needs and asks the
// host driver to capture each one.
//
// This exists because the screenshots cannot be taken by hand at any useful
// scale: five sibling apps, several screens each, re-taken whenever the UI
// moves, and every image has to be the exact pixel size Apple validates. It
// also turns a screen that fails to build into a failing test rather than a
// screenshot nobody noticed was missing.
//
// Run it with tool/screenshots.sh, which supplies the simulator and fixtures.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:retro_dosbox/main.dart' as app;

/// Skips the launch-a-program shot. That one starts the real core, which holds
/// the isolate long enough that the driver's connection can drop -- so it is
/// separable from the static screens, which must not be lost with it.
const bool kSkipRunning = bool.fromEnvironment('SKIP_RUNNING');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Settles, then captures. pumpAndSettle alone is not enough: the library
  /// scans the games folder off the main isolate, so the grid arrives after
  /// the frame that "settled" and an immediate capture catches an empty shelf.
  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await binding.takeScreenshot(name);
  }

  Finder byText(String s) => find.textContaining(s, findRichText: true);

  /// A finder for the BUTTON carrying this label, not merely the text.
  /// These screens instruct as well as offer, and a plain text finder happily
  /// takes the sentence that mentions the control instead of the control.
  Finder button(String label) {
    final text = byText(label);
    for (final type in <Type>[
      ElevatedButton,
      FilledButton,
      OutlinedButton,
      TextButton,
      InkWell,
    ]) {
      final f = find.ancestor(of: text, matching: find.byType(type));
      if (f.evaluate().isNotEmpty) return f;
    }
    return text;
  }

  /// Opens a rail category and PROVES it opened, by waiting for something only
  /// that screen shows. Without the proof a tap that lands on nothing leaves
  /// the library up, every later capture is the same library, and the run
  /// reports success with a set of identical screenshots.
  Future<void> openTab(
      WidgetTester tester, String title, String marker) async {
    final entry = button(title);
    if (entry.evaluate().isEmpty) {
      await binding.takeScreenshot('FAILED-looking-for-$title');
      fail('no rail entry titled "$title"');
    }
    await tester.tap(entry.first);
    await tester.pumpAndSettle();
    if (byText(marker).evaluate().isEmpty) {
      await binding.takeScreenshot('FAILED-opening-$title');
      fail('tapped "$title" but "$marker" never appeared -- '
          'the panel did not change');
    }
  }

  /// Returns to the workbench when a screen opened as its own route.
  Future<void> backToWorkbench(WidgetTester tester) async {
    try {
      await tester.pageBack();
      await tester.pumpAndSettle();
      return;
    } catch (_) {
      // pageBack fails two ways that both land here: nothing was pushed, or
      // the route's back control is a plain IconButton rather than one of the
      // three widget types it knows about.
    }
    for (final icon in <IconData>[
      Icons.arrow_back_ios,
      Icons.arrow_back_ios_new,
      Icons.arrow_back,
      Icons.chevron_left,
    ]) {
      final f = find.widgetWithIcon(IconButton, icon);
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first, warnIfMissed: false);
        await tester.pumpAndSettle();
        return;
      }
    }
  }

  /// Waits in REAL time for a finder to match.
  ///
  /// pumpAndSettle is not enough for this app's opening: the wizard types its
  /// text out with a timer, so the frame that "settles" is one with the boot
  /// text half-written and no buttons on screen yet. Tapping then finds
  /// nothing and the run carries on against a screen that has not arrived.
  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (f.evaluate().isNotEmpty) return true;
      await tester.pump(const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<bool> tapIfPresent(WidgetTester tester, Finder f) async {
    if (f.evaluate().isEmpty) return false;
    await tester.tap(f.first, warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    return true;
  }

  testWidgets('captures the listing screenshots', (tester) async {
    app.main();
    await tester.pump(const Duration(seconds: 1));

    // Wait for the app to actually finish arriving -- either the wizard's
    // controls or the workbench's search field. Whichever appears first is
    // where this run starts.
    await waitFor(
        tester,
        find.byWidgetPredicate((w) =>
            w is Text &&
            (w.data?.contains('Store Compliance') == true ||
                w.data?.contains('Search') == true)));

    // The wizard is what a reviewer meets on a fresh install, so it belongs in
    // the listing. Detected by a control only it has, rather than by a title.
    final onWizard = byText('Store Compliance').evaluate().isNotEmpty;
    if (onWizard) {
      await shoot(tester, '01-setup-wizard');
      // "Skip for now" with no folder chosen, "Continue" once there is one.
      if (!await tapIfPresent(tester, button('Continue'))) {
        await tapIfPresent(tester, button('Skip for now'));
      }
      await tester.pumpAndSettle(const Duration(seconds: 2));
    }
    await shoot(tester, '02-library');

    // <rail title, screenshot name, a string only that screen shows>
    for (final entry in <List<String>>[
      <String>['Compliance', '03-store-compliance', 'What this app ships'],
      <String>['Paths', '04-paths', 'Games folder'],
      <String>['Video', '05-video', 'Screen size'],
      // Markers must be visible WITHOUT scrolling: these panels are lazy
      // lists, so a string further down is simply not built yet and reads as
      // "the panel did not change" when the panel changed perfectly well.
      <String>['Input', '06-input', 'Input Settings'],
      <String>['Engine', '07-engine', 'DOSBox-X Configuration'],
      <String>['About', '08-about', 'What this is'],
    ]) {
      await openTab(tester, entry[0], entry[2]);
      await shoot(tester, entry[1]);
      await backToWorkbench(tester);
    }

    await openTab(tester, 'Games', 'Search');
    await shoot(tester, '09-library');

    if (!kSkipRunning && await tapIfPresent(tester, byText('Demo'))) {
      // Emulation needs real time, not pumped frames: the core runs on its own
      // thread, and that thread is not driven by the test clock.
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await shoot(tester, '10-running');
    }
  });
}
