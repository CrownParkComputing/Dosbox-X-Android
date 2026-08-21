// dart:ffi bindings to native/dosbox_core/bridge/dosbox_bridge.h.
//
// Mechanical wrapper, no policy: every method here maps to exactly one C
// entry point. Decisions about when to poll, what to cache and how to present
// failures live in the callers (RetroDosboxCore implementors' consumers), not here.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'retrodosbox_core.dart';

// --- Native function signatures --------------------------------------------

typedef _InitNative = Void Function(Pointer<Utf8> resourceDir);
typedef _InitDart = void Function(Pointer<Utf8> resourceDir);

typedef _StartNative = Int32 Function(Pointer<Utf8> confPath);
typedef _StartDart = int Function(Pointer<Utf8> confPath);

typedef _Int32VoidNative = Int32 Function();
typedef _Int32VoidDart = int Function();

typedef _Uint64VoidNative = Uint64 Function();
typedef _Uint64VoidDart = int Function();

typedef _VoidInt32Native = Void Function(Int32 a);
typedef _VoidInt32Dart = void Function(int a);

typedef _Int32Int32Native = Int32 Function(Int32 a);
typedef _Int32Int32Dart = int Function(int a);

typedef _VoidInt32x2Native = Void Function(Int32 a, Int32 b);
typedef _VoidInt32x2Dart = void Function(int a, int b);

typedef _JoystickNative = Void Function(
    Int32 port, Int32 mask, Int32 axisX, Int32 axisY);
typedef _JoystickDart = void Function(
    int port, int mask, int axisX, int axisY);

typedef _Int32StrNative = Int32 Function(Pointer<Utf8> s);
typedef _Int32StrDart = int Function(Pointer<Utf8> s);

typedef _GetFramebufferNative = Pointer<Uint32> Function(
    Pointer<Int32> outWidth, Pointer<Int32> outHeight,
    Pointer<Int32> outPitchBytes);
typedef _GetFramebufferDart = Pointer<Uint32> Function(
    Pointer<Int32> outWidth, Pointer<Int32> outHeight,
    Pointer<Int32> outPitchBytes);

typedef _BufNative = Int32 Function(Pointer<Utf8> buf, Int32 bufLen);
typedef _BufDart = int Function(Pointer<Utf8> buf, int bufLen);

typedef _SectionBufNative = Int32 Function(
    Pointer<Utf8> section, Pointer<Utf8> buf, Int32 bufLen);
typedef _SectionBufDart = int Function(
    Pointer<Utf8> section, Pointer<Utf8> buf, int bufLen);

typedef _ConfigSetNative = Int32 Function(
    Pointer<Utf8> section, Pointer<Utf8> property, Pointer<Utf8> value);
typedef _ConfigSetDart = int Function(
    Pointer<Utf8> section, Pointer<Utf8> property, Pointer<Utf8> value);

/// One frame, copied out of the core's buffer.
///
/// The copy is not optional: the mainloop overwrites its framebuffer in place
/// on its own thread, so anything we hand to the rasterizer has to be ours.
class FrameSnapshot {
  final int width;
  final int height;

  /// Pixels as 0xAARRGGBB little-endian words, which is B,G,R,A in memory
  /// order -- i.e. ui.PixelFormat.bgra8888, no conversion needed. Rows are
  /// tightly packed at [width] words even when the native pitch was larger;
  /// getFramebuffer un-strides while copying.
  final Uint32List pixels;

  const FrameSnapshot({
    required this.width,
    required this.height,
    required this.pixels,
  });

  /// A view of [pixels] as bytes, for decodeImageFromPixels.
  Uint8List get bytes => Uint8List.view(
      pixels.buffer, pixels.offsetInBytes, pixels.lengthInBytes);
}

/// Thin wrapper around libdosboxcore's C ABI.
class RetroDosboxCoreBindings implements RetroDosboxCore {
  final DynamicLibrary _lib;

  late final _InitDart _init;
  late final _StartDart _start;
  late final _Int32VoidDart _stop;
  late final _Int32VoidDart _isRunning;
  late final _VoidInt32Dart _setPaused;
  late final _VoidInt32x2Dart _keyEvent;
  late final _VoidInt32x2Dart _mouseMotion;
  late final _VoidInt32x2Dart _mousePosition;
  late final _VoidInt32x2Dart _mouseButton;
  late final _JoystickDart _joystick;
  late final _Int32StrDart _sendCommand;
  late final _Int32Int32Dart _saveState;
  late final _Int32Int32Dart _loadState;
  late final _Int32Int32Dart _stateIsEmpty;
  late final _GetFramebufferDart _getFramebuffer;
  late final _Uint64VoidDart _getFrameCounter;
  late final _Int32VoidDart _getPixelAspect;
  late final _BufDart _configSections;
  late final _SectionBufDart _configSectionProperties;
  late final _ConfigSetDart _configSet;
  late final _Int32VoidDart _configSave;
  late final _Int32VoidDart _getFps;
  late final _Int32VoidDart _getAudioLevel;
  late final _Int32VoidDart _getCycles;
  late final _BufDart _getRunningProgram;
  late final _BufDart _getStatusLine;

  bool _paused = false;

  RetroDosboxCoreBindings._(this._lib) {
    _init = _lib
        .lookup<NativeFunction<_InitNative>>('dosbox_core_init')
        .asFunction();
    _start = _lib
        .lookup<NativeFunction<_StartNative>>('dosbox_core_start')
        .asFunction();
    _stop = _lib
        .lookup<NativeFunction<_Int32VoidNative>>('dosbox_core_stop')
        .asFunction();
    _isRunning = _lib
        .lookup<NativeFunction<_Int32VoidNative>>('dosbox_core_is_running')
        .asFunction();
    _setPaused = _lib
        .lookup<NativeFunction<_VoidInt32Native>>('dosbox_core_set_paused')
        .asFunction();
    _keyEvent = _lib
        .lookup<NativeFunction<_VoidInt32x2Native>>('dosbox_core_key_event')
        .asFunction();
    _mouseMotion = _lib
        .lookup<NativeFunction<_VoidInt32x2Native>>('dosbox_core_mouse_motion')
        .asFunction();
    _mousePosition = _lib
        .lookup<NativeFunction<_VoidInt32x2Native>>(
            'dosbox_core_mouse_position')
        .asFunction();
    _mouseButton = _lib
        .lookup<NativeFunction<_VoidInt32x2Native>>('dosbox_core_mouse_button')
        .asFunction();
    _joystick = _lib
        .lookup<NativeFunction<_JoystickNative>>('dosbox_core_joystick')
        .asFunction();
    _sendCommand = _lib
        .lookup<NativeFunction<_Int32StrNative>>('dosbox_core_send_command')
        .asFunction();
    _saveState = _lib
        .lookup<NativeFunction<_Int32Int32Native>>('dosbox_core_save_state')
        .asFunction();
    _loadState = _lib
        .lookup<NativeFunction<_Int32Int32Native>>('dosbox_core_load_state')
        .asFunction();
    _stateIsEmpty = _lib
        .lookup<NativeFunction<_Int32Int32Native>>(
            'dosbox_core_state_is_empty')
        .asFunction();
    _getFramebuffer = _lib
        .lookup<NativeFunction<_GetFramebufferNative>>(
            'dosbox_core_get_framebuffer')
        .asFunction();
    _getFrameCounter = _lib
        .lookup<NativeFunction<_Uint64VoidNative>>(
            'dosbox_core_get_frame_counter')
        .asFunction();
    _getPixelAspect = _lib
        .lookup<NativeFunction<_Int32VoidNative>>(
            'dosbox_core_get_pixel_aspect_x1000')
        .asFunction();
    _configSections = _lib
        .lookup<NativeFunction<_BufNative>>('dosbox_core_config_sections')
        .asFunction();
    _configSectionProperties = _lib
        .lookup<NativeFunction<_SectionBufNative>>(
            'dosbox_core_config_section_properties')
        .asFunction();
    _configSet = _lib
        .lookup<NativeFunction<_ConfigSetNative>>('dosbox_core_config_set')
        .asFunction();
    _configSave = _lib
        .lookup<NativeFunction<_Int32VoidNative>>('dosbox_core_config_save')
        .asFunction();
    _getFps = _lib
        .lookup<NativeFunction<_Int32VoidNative>>('dosbox_core_get_fps')
        .asFunction();
    _getAudioLevel = _lib
        .lookup<NativeFunction<_Int32VoidNative>>(
            'dosbox_core_get_audio_level')
        .asFunction();
    _getCycles = _lib
        .lookup<NativeFunction<_Int32VoidNative>>('dosbox_core_get_cycles')
        .asFunction();
    _getRunningProgram = _lib
        .lookup<NativeFunction<_BufNative>>(
            'dosbox_core_get_running_program')
        .asFunction();
    _getStatusLine = _lib
        .lookup<NativeFunction<_BufNative>>('dosbox_core_get_status_line')
        .asFunction();
  }

  /// Loads libdosboxcore from [libraryPath], or by bare name when null.
  ///
  /// Android returns null for the path deliberately: the .so ships in
  /// `jniLibs/<abi>/` and the OS loader resolves it by bare name.
  factory RetroDosboxCoreBindings.load({String? libraryPath}) {
    final DynamicLibrary lib;
    if (Platform.isLinux || Platform.isAndroid) {
      lib = DynamicLibrary.open(libraryPath ?? 'libdosboxcore.so');
    } else if (Platform.isIOS) {
      // The core ships as libdosboxcore.framework inside the app bundle's
      // Frameworks dir. iosbox offers no supported way to add link flags to
      // the Runner target, so the dylib is bundled but NOT linked -- its
      // symbols are not in the global namespace until something dlopens it,
      // and nothing else references it, so process() would find nothing.
      // See RetroDosboxNativePaths.coreLibraryPath.
      lib = libraryPath != null
          ? DynamicLibrary.open(libraryPath)
          : DynamicLibrary.process();
    } else if (Platform.isMacOS) {
      lib = DynamicLibrary.process();
    } else if (Platform.isWindows) {
      lib = DynamicLibrary.open(libraryPath ?? 'dosboxcore.dll');
    } else {
      throw UnsupportedError('RetroDosboxCoreBindings.load: unsupported platform '
          '${Platform.operatingSystem}');
    }
    return RetroDosboxCoreBindings._(lib);
  }

  @override
  void init(String resourceDir) => _withUtf8(resourceDir, (p) {
        _init(p);
        return 0;
      });

  @override
  int start(String confPath) => _withUtf8(confPath, _start);

  @override
  int stop() => _stop();

  @override
  bool get isRunning => _isRunning() != 0;

  @override
  bool get isPaused => _paused;

  @override
  void setPaused(bool paused) {
    _paused = paused;
    _setPaused(paused ? 1 : 0);
  }

  @override
  void keyEvent(int sdlScancode, bool pressed) =>
      _keyEvent(sdlScancode, pressed ? 1 : 0);

  @override
  void mouseMotion(int dx, int dy) => _mouseMotion(dx, dy);

  @override
  void mousePosition(double x, double y) => _mousePosition(
      (x.clamp(0.0, 1.0) * 1000).round(), (y.clamp(0.0, 1.0) * 1000).round());

  @override
  void mouseButton(int button, bool pressed) =>
      _mouseButton(button, pressed ? 1 : 0);

  @override
  void joystick(int port, int mask, {double axisX = 0, double axisY = 0}) =>
      _joystick(port, mask, (axisX.clamp(-1.0, 1.0) * 1000).round(),
          (axisY.clamp(-1.0, 1.0) * 1000).round());

  @override
  int sendCommand(String line) => _withUtf8(line, _sendCommand);

  @override
  int saveState(int slot) => _saveState(slot);

  @override
  int loadState(int slot) => _loadState(slot);

  @override
  bool? stateIsEmpty(int slot) {
    final r = _stateIsEmpty(slot);
    return r < 0 ? null : r != 0;
  }

  @override
  List<String> configSections() {
    final text = _readStringBuffer(_configSections);
    if (text == null) return const <String>[];
    return text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  @override
  List<RetroDosboxConfigProperty> configSectionProperties(String section) {
    final json = _readSectionBuffer(section);
    if (json == null || json.isEmpty) return const <RetroDosboxConfigProperty>[];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const <RetroDosboxConfigProperty>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(RetroDosboxConfigProperty.fromJson)
          .toList(growable: false);
    } on FormatException {
      // A malformed reflection payload is a native bug, but it must not take
      // the settings screen down with it.
      return const <RetroDosboxConfigProperty>[];
    }
  }

  @override
  bool configSet(String section, String property, String value) {
    final pSection = section.toNativeUtf8();
    final pProperty = property.toNativeUtf8();
    final pValue = value.toNativeUtf8();
    try {
      return _configSet(pSection, pProperty, pValue) == RetroDosboxResult.ok;
    } finally {
      malloc.free(pSection);
      malloc.free(pProperty);
      malloc.free(pValue);
    }
  }

  @override
  bool configSave() => _configSave() == RetroDosboxResult.ok;

  @override
  int get fps => _getFps();

  @override
  int get audioLevel => _getAudioLevel();

  @override
  int get cycles => _getCycles();

  @override
  String? get runningProgram {
    final s = _readStringBuffer(_getRunningProgram);
    return (s == null || s.isEmpty) ? null : s;
  }

  @override
  String? get statusLine {
    final s = _readStringBuffer(_getStatusLine);
    return (s == null || s.isEmpty) ? null : s;
  }

  @override
  int get frameCounter => _getFrameCounter();

  @override
  double? get pixelAspect {
    final v = _getPixelAspect();
    return v <= 0 ? null : v / 1000.0;
  }

  @override
  FrameSnapshot? getFramebuffer() {
    final outW = malloc<Int32>();
    final outH = malloc<Int32>();
    final outPitch = malloc<Int32>();
    try {
      final ptr = _getFramebuffer(outW, outH, outPitch);
      if (ptr == nullptr) return null;
      final w = outW.value;
      final h = outH.value;
      if (w <= 0 || h <= 0) return null;

      // Honour the native pitch rather than assuming w*4: DOSBox-X's render
      // stride is the scaler's, not the visible width's, and on the xBRZ path
      // in particular they differ. Copy row by row into a tightly packed
      // buffer so the Dart side can treat it as w*h.
      final pitchWords = outPitch.value ~/ 4;
      if (pitchWords == w) {
        return FrameSnapshot(
          width: w,
          height: h,
          pixels: Uint32List.fromList(ptr.asTypedList(w * h)),
        );
      }
      final src = ptr.asTypedList(pitchWords * h);
      final dst = Uint32List(w * h);
      for (int y = 0; y < h; y++) {
        dst.setRange(y * w, y * w + w, src, y * pitchWords);
      }
      return FrameSnapshot(width: w, height: h, pixels: dst);
    } finally {
      malloc.free(outW);
      malloc.free(outH);
      malloc.free(outPitch);
    }
  }

  // --- Buffer-convention helpers -------------------------------------------

  /// The bridge's string getters write into a caller buffer and return the
  /// length the full answer needed, so an undersized buffer is a retryable
  /// condition rather than truncation we silently accept.
  static const int _initialBufferBytes = 4096;

  String? _readStringBuffer(_BufDart fn) {
    int capacity = _initialBufferBytes;
    for (int attempt = 0; attempt < 2; attempt++) {
      final buf = malloc<Uint8>(capacity).cast<Utf8>();
      try {
        final needed = fn(buf, capacity);
        if (needed < 0) return null;
        if (needed < capacity) return buf.toDartString();
        capacity = needed + 1;
      } finally {
        malloc.free(buf);
      }
    }
    return null;
  }

  String? _readSectionBuffer(String section) {
    final pSection = section.toNativeUtf8();
    try {
      int capacity = _initialBufferBytes;
      for (int attempt = 0; attempt < 2; attempt++) {
        final buf = malloc<Uint8>(capacity).cast<Utf8>();
        try {
          final needed = _configSectionProperties(pSection, buf, capacity);
          if (needed < 0) return null;
          if (needed < capacity) return buf.toDartString();
          capacity = needed + 1;
        } finally {
          malloc.free(buf);
        }
      }
      return null;
    } finally {
      malloc.free(pSection);
    }
  }

  static int _withUtf8(String s, int Function(Pointer<Utf8>) body) {
    final p = s.toNativeUtf8();
    try {
      return body(p);
    } finally {
      malloc.free(p);
    }
  }
}
