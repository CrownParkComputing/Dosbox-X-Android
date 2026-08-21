import 'package:flutter/foundation.dart';

/// The in-game UI state that is set from OUTSIDE the emulator view: whether
/// the on-screen keyboard is up, and whether the picture is acting as a
/// trackpad.
///
/// It lives here rather than inside EmulatorScreen because the buttons that
/// toggle it sit in the workbench's shell, on the status row below the
/// picture, not over it. The panel's border is the edge of the emulated
/// machine, and chrome belongs outside it -- drawn ON the picture, these
/// buttons cover the corner where DOS games put their own UI. Two widgets in
/// different subtrees have to agree on one answer, so the answer cannot be
/// private to either of them.
class EmulatorUiState extends ChangeNotifier {
  bool _keyboardVisible = false;
  bool _mouseMode = false;

  bool get keyboardVisible => _keyboardVisible;
  bool get mouseMode => _mouseMode;

  set keyboardVisible(bool value) {
    if (_keyboardVisible == value) return;
    _keyboardVisible = value;
    notifyListeners();
  }

  set mouseMode(bool value) {
    if (_mouseMode == value) return;
    _mouseMode = value;
    notifyListeners();
  }

  void toggleKeyboard() => keyboardVisible = !_keyboardVisible;
  void toggleMouseMode() => mouseMode = !_mouseMode;

  /// Leaving a session must not leave the next one in a mode the user did not
  /// ask for -- trackpad mouse especially, which turns the whole picture into
  /// a pointer surface and makes a joystick game unplayable until it is found
  /// and turned off.
  void reset() {
    if (!_keyboardVisible && !_mouseMode) return;
    _keyboardVisible = false;
    _mouseMode = false;
    notifyListeners();
  }
}
