// A DosboxCore that emulates nothing.
//
// The native core is a slow, awkward build (a cross-compiled DOSBox-X tree
// plus this project's bridge, neither of which CI can produce -- see
// docs/NATIVE_BUILD.md), so the entire Flutter UI is built and run against
// this instead. It also lets `flutter test` exercise the screens with no
// native library, no device and no DOS game files.
//
// It is deliberately not a silent no-op: it renders a recognisable animated
// test pattern and reports plausible fps/cycles, so "the UI is wired up but
// there is no core" looks obviously different from "the core is running but
// producing black frames". Getting those two confused wastes hours.
import 'dart:typed_data';

import 'dosbox_bindings.dart' show FrameSnapshot;
import 'dosbox_core.dart';

class StubDosboxCore implements DosboxCore {
  /// Mode 13h dimensions -- the classic DOS 320x200 that most games this
  /// front end targets actually ran in, so layout gets tested against a
  /// realistically non-square-pixel frame rather than a tidy 4:3 one.
  static const int _width = 320;
  static const int _height = 200;

  bool _running = false;
  bool _paused = false;
  int _frame = 0;
  String? _confPath;

  /// The last command sent via [sendCommand], exposed for tests asserting the
  /// UI issued the right DOS command.
  final List<String> sentCommands = <String>[];

  final Set<int> _emptySlots = {
    for (int i = 0; i < DosboxLimits.slotCount; i++) i
  };

  @override
  void init(String resourceDir) {}

  @override
  int start(String confPath) {
    if (_running) return DosboxResult.alreadyStarted;
    _confPath = confPath;
    _running = true;
    return DosboxResult.ok;
  }

  @override
  int stop() {
    // Mirrors the real bridge's behaviour rather than the behaviour we wish
    // it had: DOSBox-X has no working teardown, so a UI that only ever ran
    // against a cooperative stub would be built on a false assumption.
    return DosboxResult.err;
  }

  @override
  bool get isRunning => _running;

  @override
  bool get isPaused => _paused;

  @override
  void setPaused(bool paused) => _paused = paused;

  @override
  void keyEvent(int sdlScancode, bool pressed) {}

  @override
  void mouseMotion(int dx, int dy) {}

  @override
  void mousePosition(double x, double y) {}

  @override
  void mouseButton(int button, bool pressed) {}

  @override
  void joystick(int port, int mask, {double axisX = 0, double axisY = 0}) {}

  @override
  int sendCommand(String line) {
    if (!_running) return DosboxResult.notRunning;
    sentCommands.add(line);
    return DosboxResult.ok;
  }

  @override
  int saveState(int slot) {
    if (!_running) return DosboxResult.notRunning;
    if (slot < 0 || slot >= DosboxLimits.slotCount) return DosboxResult.err;
    _emptySlots.remove(slot);
    return DosboxResult.ok;
  }

  @override
  int loadState(int slot) {
    if (!_running) return DosboxResult.notRunning;
    if (slot < 0 || slot >= DosboxLimits.slotCount) return DosboxResult.err;
    return _emptySlots.contains(slot) ? DosboxResult.err : DosboxResult.ok;
  }

  @override
  bool? stateIsEmpty(int slot) {
    if (slot < 0 || slot >= DosboxLimits.slotCount) return null;
    return _emptySlots.contains(slot);
  }

  /// A small but real slice of DOSBox-X's actual property set, so the
  /// generated settings UI is exercised against every widget type it has to
  /// handle: enum dropdown, bool switch, free int and free string.
  static const Map<String, List<DosConfigProperty>> _config = {
    'dosbox': [
      DosConfigProperty(
        name: 'machine',
        type: 'string',
        value: 'svga_s3',
        defaultValue: 'svga_s3',
        help: 'The type of machine DOSBox-X tries to emulate.',
        values: ['hercules', 'cga', 'ega', 'vgaonly', 'svga_s3', 'pc98'],
      ),
      DosConfigProperty(
        name: 'memsize',
        type: 'int',
        value: '16',
        defaultValue: '16',
        help: 'Amount of memory DOSBox-X has in megabytes.',
        values: [],
      ),
    ],
    'cpu': [
      DosConfigProperty(
        name: 'core',
        type: 'string',
        value: 'auto',
        defaultValue: 'auto',
        help: 'CPU core used in emulation.',
        values: ['auto', 'dynamic', 'normal', 'simple'],
      ),
      DosConfigProperty(
        name: 'cycles',
        type: 'string',
        value: 'auto',
        defaultValue: 'auto',
        help: 'Amount of instructions DOSBox-X tries to emulate each '
            'millisecond.',
        values: [],
      ),
    ],
    'render': [
      DosConfigProperty(
        name: 'aspect',
        type: 'bool',
        value: 'false',
        defaultValue: 'false',
        help: 'Aspect ratio correction.',
        values: ['true', 'false'],
      ),
    ],
  };

  @override
  List<String> configSections() => _config.keys.toList(growable: false);

  @override
  List<DosConfigProperty> configSectionProperties(String section) =>
      _config[section] ?? const <DosConfigProperty>[];

  @override
  bool configSet(String section, String property, String value) =>
      _config.containsKey(section);

  @override
  bool configSave() => true;

  @override
  int get fps => _running && !_paused ? 60 : 0;

  @override
  int get audioLevel => _running && !_paused ? 30 + (_frame % 40) : 0;

  @override
  int get cycles => _running ? 3000 : 0;

  @override
  String? get runningProgram => _running ? 'STUB' : null;

  @override
  String? get statusLine =>
      _running ? 'DOSBox-X stub core - $_confPath' : null;

  @override
  int get frameCounter => _frame;

  /// 320x200 stretched to 4:3, the real mode 13h ratio (1.2), so aspect
  /// handling in the view is tested rather than accidentally bypassed.
  @override
  double? get pixelAspect => _running ? 1.2 : null;

  @override
  FrameSnapshot? getFramebuffer() {
    if (!_running) return null;
    if (!_paused) _frame++;

    // 0xAARRGGBB words, matching the real bridge's format. Animated diagonal
    // bars plus a moving highlight: any tearing, stride bug or stale-frame
    // bug in the view layer shows up immediately as a visual artefact.
    final pixels = Uint32List(_width * _height);
    final t = _frame;
    for (int y = 0; y < _height; y++) {
      for (int x = 0; x < _width; x++) {
        final band = ((x + y + t) ~/ 16) % 6;
        final int r, g, b;
        switch (band) {
          case 0:
            r = 0x2D; g = 0x8C; b = 0xFF;
          case 1:
            r = 0x00; g = 0xFF; b = 0xCC;
          case 2:
            r = 0xFF; g = 0xC1; b = 0x07;
          case 3:
            r = 0xE5; g = 0x39; b = 0x35;
          case 4:
            r = 0x8E; g = 0x24; b = 0xAA;
          default:
            r = 0x19; g = 0x1D; b = 0x22;
        }
        pixels[y * _width + x] =
            0xFF000000 | (r << 16) | (g << 8) | b;
      }
    }
    return FrameSnapshot(width: _width, height: _height, pixels: pixels);
  }
}
