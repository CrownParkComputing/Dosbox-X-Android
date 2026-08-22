import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:retro_dosbox/screens/about_screen.dart';
import 'package:retro_dosbox/services/app_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('About reports the current and wizard-completed builds', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppPrefs.setSetupCompletedForBuild('1.4.0+106');
    PackageInfo.setMockInitialValues(
      appName: 'Retro-DosBox',
      packageName: 'com.crownparkcomputing.retrodosbox',
      version: '1.4.0',
      buildNumber: '107',
      buildSignature: '',
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AboutScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Current build: 1.4.0+107'), findsOneWidget);
    expect(
      find.textContaining('Wizard completed for: 1.4.0+106'),
      findsOneWidget,
    );
  });
}
