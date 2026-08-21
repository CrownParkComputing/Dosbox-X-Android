// A RetroDosboxCore that emulates nothing.
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

import 'retrodosbox_bindings.dart' show FrameSnapshot;
import 'retrodosbox_core.dart';

class StubRetroDosboxCore implements RetroDosboxCore {
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
    for (int i = 0; i < RetroDosboxLimits.slotCount; i++) i
  };

  @override
  void init(String resourceDir) {}

  @override
  int start(String confPath) {
    if (_running) return RetroDosboxResult.alreadyStarted;
    _confPath = confPath;
    _running = true;
    return RetroDosboxResult.ok;
  }

  @override
  int stop() {
    // The bridge actually tears the engine down and the code calling this
    // treats "stop returned err" as "session is dead anyway, drop our side
    // of the state". The Dart side already does that, but on the stub
    // leaving `_running = true` meant `core.isRunning` kept reporting true
    // after stop -- the sidebar footer kept drawing the running title, the
    // alreadyStarted guard rejected every fresh launch, and the user-visible
    // symptom was "I closed the session but it still says session open and
    // it is". Mark the stub as actually stopped regardless of the returned
    // code: the engine is gone from our point of view either way.
    _running = false;
    _paused = false;
    _frame = 0;
    return RetroDosboxResult.err;
  }

  @override
  bool attachSharedFrameIfPossible(String path) {
    // Nothing to attach to: the stub has no engine anywhere, in this process
    // or any other.
    return false;
  }

  @override
  void detachSharedFrameIfAttached() {}

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
    if (!_running) return RetroDosboxResult.notRunning;
    sentCommands.add(line);
    return RetroDosboxResult.ok;
  }

  @override
  int saveState(int slot) {
    if (!_running) return RetroDosboxResult.notRunning;
    if (slot < 0 || slot >= RetroDosboxLimits.slotCount) return RetroDosboxResult.err;
    _emptySlots.remove(slot);
    return RetroDosboxResult.ok;
  }

  @override
  int loadState(int slot) {
    if (!_running) return RetroDosboxResult.notRunning;
    if (slot < 0 || slot >= RetroDosboxLimits.slotCount) return RetroDosboxResult.err;
    return _emptySlots.contains(slot) ? RetroDosboxResult.err : RetroDosboxResult.ok;
  }

  @override
  bool? stateIsEmpty(int slot) {
    if (slot < 0 || slot >= RetroDosboxLimits.slotCount) return null;
    return _emptySlots.contains(slot);
  }

  /// A small but real slice of DOSBox-X's actual property set, so the
  /// generated settings UI is exercised against every widget type it has to
  /// handle: enum dropdown, bool switch, free int and free string.
  static const Map<String, List<RetroDosboxConfigProperty>> _config = {
    'dosbox': [
      RetroDosboxConfigProperty(
        name: 'machine',
        type: 'string',
        value: 'svga_s3',
        defaultValue: 'svga_s3',
        help: 'The type of machine DOSBox-X tries to emulate.',
        values: ['hercules', 'cga', 'ega', 'vgaonly', 'svga_s3', 'pc98'],
      ),
      RetroDosboxConfigProperty(
        name: 'memsize',
        type: 'int',
        value: '16',
        defaultValue: '16',
        help: 'Amount of memory DOSBox-X has in megabytes.',
        values: [],
      ),
    ],
    'cpu': [
      RetroDosboxConfigProperty(
        name: 'core',
        type: 'string',
        value: 'auto',
        defaultValue: 'auto',
        help: 'CPU core used in emulation.',
        values: ['auto', 'dynamic', 'normal', 'simple'],
      ),
      RetroDosboxConfigProperty(
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
      RetroDosboxConfigProperty(
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
  List<RetroDosboxConfigProperty> configSectionProperties(String section) =>
      _config[section] ?? const <RetroDosboxConfigProperty>[];

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
