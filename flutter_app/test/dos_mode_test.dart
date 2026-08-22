// Which DOS boots, and the FreeDOS image behind it.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:retro_dosbox/services/dos_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('dosbox_mode_test');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() => support.deleteSync(recursive: true));

  test('the built-in DOS is the default', () async {
    // It needs no boot at all, so it is the mode that works on the widest set
    // of hardware. A user who never opens the compliance page gets it.
    expect(await DosModeService.current(), DosMode.builtIn);
  });

  test('the chosen mode survives', () async {
    await DosModeService.set(DosMode.freeDos);
    expect(await DosModeService.current(), DosMode.freeDos);
    await DosModeService.set(DosMode.builtIn);
    expect(await DosModeService.current(), DosMode.builtIn);
  });

  test('the bundled image is a real FreeDOS floppy', () async {
    final bytes =
        (await rootBundle.load('assets/freedos/FD13BOOT.img')).buffer.asUint8List();

    // A 1.44MB floppy, exactly. DOSBox-X's IMGMOUNT infers the geometry from
    // the size, so a truncated image is not a smaller floppy -- it is a
    // mount that fails or, worse, one that succeeds and reads garbage.
    expect(bytes.length, 1474560);
    // The OEM identifier in the FAT boot sector. This is what says the image is
    // FreeDOS rather than some other DOS someone dropped in later.
    final oem = String.fromCharCodes(bytes.sublist(3, 11));
    expect(oem, 'FRDOS5.1');
    // 0x55AA closes a boot sector; without it nothing will boot from it.
    expect(bytes[510], 0x55);
    expect(bytes[511], 0xAA);
  });

  test('extracting the image writes a real file, once', () async {
    final path = await DosModeService.ensureImage();
    final file = File(path);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), 1474560);

    // Marked, then re-extracted: the second call must leave the existing file
    // alone, because IMGMOUNT may hold it and rewriting underneath a running
    // machine is not a small problem.
    final before = file.statSync().modified;
    await DosModeService.ensureImage();
    expect(file.statSync().modified, before);
  });

  test('the boot sequence mounts before it boots', () async {
    final commands = DosModeService.bootCommands('/tmp/FD13BOOT.img');
    expect(commands, hasLength(2));
    expect(commands.first, startsWith('IMGMOUNT A '));
    expect(commands.first, contains('-t floppy'));
    expect(commands.last, 'BOOT A:');
    // The path is quoted: application support paths on iOS contain the app's
    // container UUID and, on some hosts, spaces.
    expect(commands.first, contains('"/tmp/FD13BOOT.img"'));
  });
}
