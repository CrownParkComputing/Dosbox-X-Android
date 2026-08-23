// Host side of the screenshot run. `flutter drive` runs this on the Mac while
// integration_test/screenshots_test.dart drives the app on the simulator.
//
// Capture uses the bytes the DEVICE captured, not a fresh simctl grab.
//
// simctl was the obvious choice -- it reads the real framebuffer, so the image
// is the device's pixel size, which is what App Store Connect validates. But
// the driver receives these callbacks only after the test method has finished,
// so `simctl io screenshot` photographs whatever is on screen at the END of
// the run. Every capture came out as the final screen: nine files, one of them
// correct by coincidence, and the test passing throughout because the app
// really had visited all nine screens.
//
// The bytes handed in here were captured on the device at the moment
// takeScreenshot was called, which is the only thing that reflects the screen
// the test was actually looking at.

import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final outDir = Directory(
      Platform.environment['SHOT_DIR'] ?? 'build/screenshots')
    ..createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? a]) async {
      final file = File('${outDir.path}/$name.png');
      await file.writeAsBytes(bytes);
      stdout.writeln('captured ${file.path} (${bytes.length} bytes)');
      return true;
    },
  );
}
