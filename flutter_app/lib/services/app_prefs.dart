// Thin wrapper around shared_preferences for the handful of persisted
// settings the setup wizard and the input controls need: whether the wizard
// has been completed once (so it only shows on first run), the chosen
// app/games folder paths on the folder-scan platforms (a plain filesystem
// path rather than a SAF URI, since file_picker hands back a real path on
// both Linux and Android), and the touch-control layout.
//
// Video settings deliberately live elsewhere (VideoSettings, which is a
// listenable singleton because the emulator screen has to repaint when they
// change); these are read-on-demand one-shot values, so they stay static.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// When the on-screen joypad is shown. See [AppPrefs.getOnScreenPadMode].
enum OnScreenPadMode {
  auto('Auto', 'Hidden while a controller is connected'),
  always('Always', 'Always shown, even with a controller'),
  never('Never', 'Never shown');

  final String label;
  final String description;
  const OnScreenPadMode(this.label, this.description);

  /// Whether the pad should be on screen right now.
  bool visibleWith({required bool controllerConnected}) => switch (this) {
    OnScreenPadMode.always => true,
    OnScreenPadMode.never => false,
    OnScreenPadMode.auto => !controllerConnected,
  };

  /// Next mode when the user taps the single Quick Settings row.
  OnScreenPadMode get next =>
      OnScreenPadMode.values[(index + 1) % OnScreenPadMode.values.length];
}

class AppPrefs {
  AppPrefs._();

  static const _keySetupCompleted = 'setup_completed';
  static const _keySetupBuild = 'setup_completed_build';
  static const _keyComplianceMode = 'compliance_mode';
  static const _keyAppFolderPath = 'app_folder_path';
  static const _keyGamesFolderPath = 'games_folder_path';
  static const _keyLeftHandedInput = 'left_handed_input';
  static const _keyActionButtonAScancode = 'action_button_a_scancode';
  static const _keyActionButtonBScancode = 'action_button_b_scancode';
  static const _keyOnScreenPadMode = 'on_screen_pad_mode';
  static const _keyJoystickEnabled = 'joystick_enabled';
  static const _keySidebarHidden = 'sidebar_hidden';
  static const _keyCustomButtons = 'custom_on_screen_buttons';

  /// Sentinel stored in prefs for "leave this button as joystick fire" (no
  /// explicit key mapping). Kept private -- callers see this as `null`.
  static const int _mappingDefault = -1;

  static Future<bool> isSetupCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySetupCompleted) ?? false;
  }

  static Future<void> setSetupCompleted(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySetupCompleted, value);
  }

  /// Whether the setup choice has been completed for this exact app build.
  ///
  /// App Store and tester builds retain preferences across upgrades. A plain
  /// boolean therefore hides revised setup/compliance information forever.
  /// Recording `version+buildNumber` makes each newly numbered build show the
  /// wizard once, while ordinary launches of the same build go straight to
  /// the workbench.
  static Future<bool> setupCompletedForBuild(String build) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_keySetupCompleted) ?? false)) return false;
    return prefs.getString(_keySetupBuild) == build;
  }

  static Future<void> setSetupCompletedForBuild(String build) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySetupCompleted, true);
    await prefs.setString(_keySetupBuild, build);
  }

  /// The build whose wizard choice is currently recorded, shown on About so
  /// a tester can verify why setup did or did not appear.
  static Future<String?> getSetupCompletedBuild() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySetupBuild);
  }

  /// Store-review isolation mode.
  ///
  /// On for a clean install so a reviewer sees only content whose provenance
  /// ships with the app. While it is on the workbench does not resolve, scan,
  /// list or launch the user's games folder. The user can turn it off from the
  /// permanently available Compliance page.
  static Future<bool> getComplianceMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyComplianceMode) ?? true;
  }

  static Future<void> setComplianceMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyComplianceMode, value);
  }

  static Future<String?> getAppFolderPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyAppFolderPath);
  }

  static Future<void> setAppFolderPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAppFolderPath, path);
  }

  static Future<String?> getGamesFolderPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyGamesFolderPath);
  }

  static Future<void> setGamesFolderPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyGamesFolderPath, path);
  }

  /// Mirrors the on-screen joystick's position from bottom-left to
  /// bottom-right of the emulator screen (position only -- direction
  /// mapping is unchanged). Set from the Input Settings tab.
  static Future<bool> getLeftHandedInput() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLeftHandedInput) ?? false;
  }

  static Future<void> setLeftHandedInput(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLeftHandedInput, value);
  }

  /// When the on-screen joypad is shown.
  ///
  /// This is ONE setting rather than two overlapping controls (a local
  /// show/hide toggle plus a separate "force visible" override, which shows
  /// up as duplicate joypad rows in Quick Settings). The three modes cover
  /// every case between them:
  ///
  ///  - [OnScreenPadMode.auto]: hide while a controller is connected. The
  ///    sensible default.
  ///  - [OnScreenPadMode.always]: keep the touch controls up regardless --
  ///    the case auto-hide alone made impossible on a handheld like the
  ///    Retroid Flip2, whose built-in gamepad is permanently "connected".
  ///  - [OnScreenPadMode.never]: no touch controls, even with no controller.
  static Future<OnScreenPadMode> getOnScreenPadMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_keyOnScreenPadMode) ?? 0;
    return (index >= 0 && index < OnScreenPadMode.values.length)
        ? OnScreenPadMode.values[index]
        : OnScreenPadMode.auto;
  }

  static Future<void> setOnScreenPadMode(OnScreenPadMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyOnScreenPadMode, mode.index);
  }

  /// Whether the emulated PC joystick is presented at all.
  ///
  /// On by default, matching C64-Retro, where the on-screen stick is gated on
  /// the pad-visibility mode alone. Off was defensible in the abstract -- many
  /// DOS games ignore the game port -- but in practice it meant a touch device
  /// launched a game with no visible controls at all and nothing on screen
  /// explaining why, which is a worse failure than a stick that does nothing
  /// in a keyboard-only title. Whether the emulated PC actually presents a
  /// joystick stays per-title (GameSettings.joystick -> joysticktype in the
  /// conf); this is only about the on-screen controls.
  static Future<bool> getJoystickEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyJoystickEnabled) ?? true;
  }

  static Future<void> setJoystickEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyJoystickEnabled, value);
  }

  /// Whether the workbench sidebar is hidden so the content panel gets the
  /// full width. The toggle lives in the bottom status bar precisely because
  /// it must stay reachable while the sidebar is hidden.
  static Future<bool> getSidebarHidden() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySidebarHidden) ?? false;
  }

  static Future<void> setSidebarHidden(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySidebarHidden, value);
  }

  /// The title to launch once the app comes back from a restart.
  ///
  /// Switching games means replacing the process - DOSBox-X cannot start twice
  /// in one - so the choice has to outlive it. Cleared as soon as it is read,
  /// because a stale one would hijack the next ordinary launch.
  static const String _keyPendingLaunch = 'pending_launch_slug';

  static Future<String?> takePendingLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final slug = prefs.getString(_keyPendingLaunch);
    if (slug != null) await prefs.remove(_keyPendingLaunch);
    return slug;
  }

  static Future<void> setPendingLaunch(String slug) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPendingLaunch, slug);
  }

  /// Extra on-screen buttons the user has added, in the order they were
  /// added (which is the order they appear on screen), as SDL scancodes.
  ///
  /// These are ADDITIONAL to the A/B action buttons. Each one sends a real
  /// key press via `dosbox_core_key_event`, so any scancode can be assigned
  /// -- `RetroDosboxKeyCatalogue` only decides which ones the picker offers and what
  /// they are labelled, it is not a limit on what can be stored here.
  static Future<List<int>> getCustomButtons() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyCustomButtons);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<int>().toList();
    } catch (_) {
      // A corrupt list costs the user their extra buttons, not the app.
      return const [];
    }
  }

  static Future<void> setCustomButtons(List<int> scancodes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCustomButtons, jsonEncode(scancodes));
  }

  /// Assignable A/B action-button mapping: null means "joystick button"
  /// (the button's default), a non-null value is an SDL scancode from
  /// `RetroDosboxScancode` sent via `dosbox_core_key_event`.
  ///
  /// [button] is 'a' or 'b'; anything else is treated as 'b'.
  static Future<int?> getActionButtonScancode(String button) async {
    final prefs = await SharedPreferences.getInstance();
    final key = button == 'a'
        ? _keyActionButtonAScancode
        : _keyActionButtonBScancode;
    final value = prefs.getInt(key) ?? _mappingDefault;
    return value == _mappingDefault ? null : value;
  }

  static Future<void> setActionButtonScancode(
    String button,
    int? scancode,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = button == 'a'
        ? _keyActionButtonAScancode
        : _keyActionButtonBScancode;
    await prefs.setInt(key, scancode ?? _mappingDefault);
  }
}
