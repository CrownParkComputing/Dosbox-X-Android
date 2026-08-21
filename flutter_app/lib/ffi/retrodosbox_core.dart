// The emulator core as the UI sees it.
//
// Everything above this line is plain Dart: screens, widgets and the save
// state service talk to a `RetroDosboxCore`, never to `dart:ffi` directly. There
// are two implementations:
//
//   - RetroDosboxCoreBindings (dosbox_bindings.dart), which opens
//     libdosboxcore.so. That class cannot even be constructed without the
//     native library present on disk, which is why this interface exists
//     rather than the concrete type being referenced everywhere.
//   - StubRetroDosboxCore (stub_dosbox_core.dart), which reports "not running"
//     for everything and draws a test pattern.
//
// The stub is not just a test fake. The native core is a separate, slow build
// (a cross-compiled DOSBox-X tree plus this project's bridge), so the whole
// Flutter UI is developed and run against the stub, and `flutter test` needs
// no native library, no device and no DOS game files.
import 'retrodosbox_bindings.dart' show FrameSnapshot;

abstract class RetroDosboxCore {
  /// Points the core at DOSBox-X's own resource tree (fonts, translations,
  /// conf template, glshaders). Must be called before [start].
  void init(String resourceDir);

  /// Boots the machine using the dosbox-x.conf at [confPath]. That file is
  /// the only channel by which a title is launched -- mounts, machine type
  /// and the [autoexec] that runs the program all live in it. Returns
  /// [RetroDosboxResult.ok] on success.
  ///
  /// Asynchronous: the machine is still booting when this returns.
  int start(String confPath);

  /// Best-effort shutdown. Returns [RetroDosboxResult.err] on builds where the
  /// core cannot be torn down -- see the note on dosbox_core_stop in
  /// native/dosbox_core/bridge/dosbox_bridge.h. Callers must not assume a
  /// second [start] will succeed.
  int stop();

  bool get isRunning;

  /// Whether the UI has asked the core to pause. Tracked on the Dart side
  /// because the native gate has no getter, and callers need to know whether
  /// a pause was already in effect before pausing themselves -- otherwise
  /// returning from the background would un-pause a session the user had
  /// deliberately paused.
  bool get isPaused;

  void setPaused(bool paused);

  // --- Input ---------------------------------------------------------------

  /// Keyboard by SDL2 scancode. Scancodes rather than characters because DOS
  /// games read the keyboard at that level; see [RetroDosboxScancode].
  void keyEvent(int sdlScancode, bool pressed);

  void mouseMotion(int dx, int dy);

  /// Absolute pointer position as a fraction of the frame, 0..1.
  void mousePosition(double x, double y);

  /// button: 0 left, 1 right, 2 middle.
  void mouseButton(int button, bool pressed);

  /// port: 0 or 1. mask: bitwise OR of [RetroDosboxJoyBits]. Axes are -1.0..1.0.
  void joystick(int port, int mask, {double axisX = 0, double axisY = 0});

  /// Types [line] into the DOS shell and presses Enter.
  int sendCommand(String line);

  // --- Save states ---------------------------------------------------------

  /// DOSBox-X's save states are slot-based, not path-based (class SaveState
  /// in its dosbox.h), so these take a slot in 0..[RetroDosboxLimits.slotCount).
  /// SaveStateService layers naming, thumbnails and eviction on top.
  int saveState(int slot);

  int loadState(int slot);

  /// null when the core is not running or the slot could not be queried.
  bool? stateIsEmpty(int slot);

  // --- Live configuration --------------------------------------------------

  /// Section names from the running engine's config system.
  List<String> configSections();

  /// The properties of one section, as reflected by the engine. Used to
  /// generate the settings UI rather than hand-maintaining a duplicate list.
  List<RetroDosboxConfigProperty> configSectionProperties(String section);

  /// Applies a property to the running engine.
  bool configSet(String section, String property, String value);

  /// Writes the running config back to the active .conf file.
  bool configSave();

  // --- Status --------------------------------------------------------------

  int get fps;

  /// Smoothed 0..100 output peak, for level meters.
  int get audioLevel;

  int get cycles;

  /// The DOS program currently executing, e.g. "DOOM", or null.
  String? get runningProgram;

  /// DOSBox-X's status line (fps/cycles/paused), or null.
  String? get statusLine;

  /// The current frame, or null before the core has drawn one.
  FrameSnapshot? getFramebuffer();

  /// Bumped once per completed frame. Lets the UI skip the copy+decode when
  /// nothing changed -- DOS text mode can sit on an identical frame for
  /// seconds at a time.
  int get frameCounter;

  /// Display aspect ratio DOSBox-X reports for the current frame, or null if
  /// unknown. Not the same as width/height: 320x200 is a 4:3 display mode.
  double? get pixelAspect;
}

/// Result codes, mirroring the #defines in dosbox_bridge.h.
class RetroDosboxResult {
  RetroDosboxResult._();

  static const int ok = 0;
  static const int err = -1;

  /// The mainloop did not service a mailbox request within its timeout.
  static const int timeout = -2;

  static const int notRunning = -3;

  /// A core is already up and this build cannot restart one in-process.
  static const int alreadyStarted = -4;
}

class RetroDosboxLimits {
  RetroDosboxLimits._();

  /// DOSBOX_SLOT_COUNT in dosbox_bridge.h.
  static const int slotCount = 10;
}

/// Emulated PC joystick bits, matching the DOSBOX_JOY_* defines.
class RetroDosboxJoyBits {
  RetroDosboxJoyBits._();

  static const int up = 0x01;
  static const int down = 0x02;
  static const int left = 0x04;
  static const int right = 0x08;
  static const int button1 = 0x10;
  static const int button2 = 0x20;
  static const int button3 = 0x40;
  static const int button4 = 0x80;
}

/// One property as reflected out of DOSBox-X's config system.
class RetroDosboxConfigProperty {
  final String name;

  /// "bool", "int", "string", "hex" or "double". Drives widget choice.
  final String type;
  final String value;
  final String defaultValue;
  final String help;

  /// The legal values, or empty when unconstrained. A non-empty list means
  /// the UI should offer a dropdown rather than a free text field.
  final List<String> values;

  const RetroDosboxConfigProperty({
    required this.name,
    required this.type,
    required this.value,
    required this.defaultValue,
    required this.help,
    required this.values,
  });

  factory RetroDosboxConfigProperty.fromJson(Map<String, dynamic> json) {
    return RetroDosboxConfigProperty(
      name: (json['name'] ?? '') as String,
      type: (json['type'] ?? 'string') as String,
      value: (json['value'] ?? '').toString(),
      defaultValue: (json['default'] ?? '').toString(),
      help: (json['help'] ?? '') as String,
      values: ((json['values'] as List<dynamic>?) ?? const <dynamic>[])
          .map((v) => v.toString())
          .toList(growable: false),
    );
  }

  bool get isBool => type == 'bool';

  bool get isEnum => values.isNotEmpty && !isBool;
}
