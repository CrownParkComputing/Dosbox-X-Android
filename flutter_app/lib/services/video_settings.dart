// Shared, persisted video settings. One source of truth for the Video
// settings screen and the in-game Quick Settings panel.
//
// Everything exposed here is applied for real by FramebufferView. Settings
// that would need new native entry points are deliberately absent rather than
// shipped as switches that do nothing -- notably DOSBox-X's own scaler
// (`render.scaler`) and output type, which live in the engine's config system
// and are reached through the generated settings screen instead
// (DosboxCore.configSet), not from here.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the DOS picture is fitted into the window.
///
/// The important difference from the VICE app: `authentic` is not a hardcoded
/// 4:3 here. DOS video modes are frequently non-square-pixel -- 320x200 and
/// 640x350 both displayed as 4:3 on real hardware, and 320x240 displayed
/// square -- so the correct ratio is whatever DOSBox-X reports for the current
/// mode (dosbox_core_get_pixel_aspect_x1000). Hardcoding 4:3 would stretch
/// every square-pixel mode.
enum AspectMode {
  /// The display aspect DOSBox-X reports for the current video mode, falling
  /// back to 4:3 if it reports nothing. Letterboxed as needed.
  authentic('Authentic'),

  /// Ignore the reported aspect and use the raw pixel dimensions.
  square('Square pixels'),

  /// Largest whole-number multiple of the emulated pixel grid that fits -- no
  /// resampling, so no shimmer on scrolling.
  integer('Integer scale'),

  /// Stretch to the whole window, ignoring aspect entirely.
  stretch('Stretch to fill');

  final String label;
  const AspectMode(this.label);
}

class VideoSettings extends ChangeNotifier {
  VideoSettings._();
  static final VideoSettings instance = VideoSettings._();

  static const _keyCrt = 'video_crt';
  static const _keyBezel = 'video_bezel';
  static const _keyAspect = 'video_aspect_mode';
  static const _keySmooth = 'video_smooth_filter';
  static const _keyRotation = 'video_rotation_quarter_turns';
  static const _keyScanline = 'video_scanline_intensity';

  bool _crt = false;
  bool _bezel = false;
  AspectMode _aspect = AspectMode.authentic;
  bool _smooth = false;
  int _rotationQuarterTurns = 0;
  double _scanlineIntensity = 0.35;
  bool _loaded = false;

  bool get crt => _crt;
  bool get bezel => _bezel;
  AspectMode get aspect => _aspect;
  bool get smooth => _smooth;
  int get rotationQuarterTurns => _rotationQuarterTurns;

  /// 0..1, how dark the CRT scanlines are drawn. Only has an effect while
  /// [crt] is on.
  double get scanlineIntensity => _scanlineIntensity;

  String get aspectLabel => _aspect.label;

  /// Loads persisted values once. Safe to call repeatedly.
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _crt = prefs.getBool(_keyCrt) ?? false;
    _bezel = prefs.getBool(_keyBezel) ?? false;
    final aspectIndex = prefs.getInt(_keyAspect) ?? AspectMode.authentic.index;
    _aspect =
        AspectMode.values[aspectIndex.clamp(0, AspectMode.values.length - 1)];
    _smooth = prefs.getBool(_keySmooth) ?? false;
    _rotationQuarterTurns = (prefs.getInt(_keyRotation) ?? 0) % 4;
    _scanlineIntensity = prefs.getDouble(_keyScanline) ?? 0.35;
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save(void Function(SharedPreferences p) write) async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    write(prefs);
  }

  void setCrt(bool value) {
    _crt = value;
    _save((p) => p.setBool(_keyCrt, value));
  }

  void setBezel(bool value) {
    _bezel = value;
    _save((p) => p.setBool(_keyBezel, value));
  }

  void setAspect(AspectMode mode) {
    _aspect = mode;
    _save((p) => p.setInt(_keyAspect, mode.index));
  }

  void setSmooth(bool value) {
    _smooth = value;
    _save((p) => p.setBool(_keySmooth, value));
  }

  void setRotationQuarterTurns(int turns) {
    _rotationQuarterTurns = turns % 4;
    _save((p) => p.setInt(_keyRotation, _rotationQuarterTurns));
  }

  void setScanlineIntensity(double value) {
    _scanlineIntensity = value.clamp(0.0, 1.0);
    _save((p) => p.setDouble(_keyScanline, _scanlineIntensity));
  }

  /// Drops every value back to its default and forgets that [load] ran, so
  /// each test starts from a clean singleton. Not used by the app.
  @visibleForTesting
  void resetForTests() {
    _crt = false;
    _bezel = false;
    _aspect = AspectMode.authentic;
    _smooth = false;
    _rotationQuarterTurns = 0;
    _scanlineIntensity = 0.35;
    _loaded = false;
  }
}
