import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_dosbox/screens/setup_wizard_screen.dart';
import 'package:retro_dosbox/services/app_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpWizard(
    WidgetTester tester, {
    required VoidCallback onComplete,
    Future<String> Function()? prepareComplianceDemo,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SetupWizardScreen(
            onComplete: onComplete,
            prepareComplianceDemo:
                prepareComplianceDemo ?? () async => 'review-demo',
          ),
        ),
      ),
    );
  }

  testWidgets('offers both startup modes without scanning first', (
    tester,
  ) async {
    await pumpWizard(tester, onComplete: () {});

    expect(find.text('Store Compliance'), findsOneWidget);
    expect(find.text('Regular Mode'), findsOneWidget);
  });

  testWidgets('Regular Mode persists the normal-library choice', (
    tester,
  ) async {
    var completed = 0;
    await pumpWizard(tester, onComplete: () => completed++);

    await tester.tap(find.text('Regular Mode'));
    await tester.pump();

    expect(completed, 1);
    expect(await AppPrefs.isSetupCompleted(), isTrue);
    expect(await AppPrefs.getComplianceMode(), isFalse);
    expect(await AppPrefs.takePendingLaunch(), isNull);
  });

  testWidgets('Store Compliance isolates the library and queues the demo', (
    tester,
  ) async {
    var completed = 0;
    await pumpWizard(
      tester,
      onComplete: () => completed++,
      prepareComplianceDemo: () async => 'free-dos-review-demo',
    );

    await tester.tap(find.text('Store Compliance'));
    await tester.pump();

    expect(completed, 1);
    expect(await AppPrefs.isSetupCompleted(), isTrue);
    expect(await AppPrefs.getComplianceMode(), isTrue);
    expect(await AppPrefs.takePendingLaunch(), 'free-dos-review-demo');
  });
}
