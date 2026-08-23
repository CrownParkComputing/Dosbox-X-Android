// Input Settings tab: everything about how touch and gamepad input reaches
// the emulated PC.
//
// Unlike the VICE app's equivalent, this screen owns its own state instead of
// being handed values and callbacks by the workbench. The reason is that all
// of these settings are read straight out of [AppPrefs] by the emulator screen
// when a session starts, so there is no in-memory owner above this widget to
// lift them into -- the preference store IS the single source of truth, and a
// second copy held by a parent would only be another thing to keep in sync.
// The load is asynchronous, so this is a StatefulWidget with a loading pass.
import 'package:flutter/material.dart';

import '../data/retrodosbox_scancodes.dart';
import '../ffi/retrodosbox_core.dart';
import '../services/app_prefs.dart';
import '../theme/retrodosbox_theme.dart';
import '../widgets/custom_key_button.dart';

class InputSettingsScreen extends StatefulWidget {
  /// Used only to fire a short test key press when the user taps one of their
  /// custom buttons here, so a binding can be checked without leaving the
  /// settings tab. Nothing on this screen configures the core itself.
  final RetroDosboxCore core;

  /// Live external-gamepad state, owned by the workbench (GamepadService).
  final bool controllerConnected;

  const InputSettingsScreen({
    super.key,
    required this.core,
    required this.controllerConnected,
  });

  @override
  State<InputSettingsScreen> createState() => _InputSettingsScreenState();
}

class _InputSettingsScreenState extends State<InputSettingsScreen> {
  bool _loading = true;
  bool _joystickEnabled = false;
  bool _leftHanded = false;
  OnScreenPadMode _padMode = OnScreenPadMode.auto;
  int? _buttonA;
  int? _buttonB;
  List<int> _customButtons = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final joystick = await AppPrefs.getJoystickEnabled();
    final leftHanded = await AppPrefs.getLeftHandedInput();
    final padMode = await AppPrefs.getOnScreenPadMode();
    final a = await AppPrefs.getActionButtonScancode('a');
    final b = await AppPrefs.getActionButtonScancode('b');
    final custom = await AppPrefs.getCustomButtons();
    if (!mounted) return;
    setState(() {
      _joystickEnabled = joystick;
      _leftHanded = leftHanded;
      _padMode = padMode;
      _buttonA = a;
      _buttonB = b;
      _customButtons = custom;
      _loading = false;
    });
  }

  // Each setter writes the preference and updates local state at the same
  // time. The write is not awaited before the rebuild on purpose: the switch
  // must move under the user's finger immediately, and shared_preferences
  // reflects the new value in memory as soon as the future is created.
  void _setJoystickEnabled(bool value) {
    setState(() => _joystickEnabled = value);
    AppPrefs.setJoystickEnabled(value);
  }

  void _setLeftHanded(bool value) {
    setState(() => _leftHanded = value);
    AppPrefs.setLeftHandedInput(value);
  }

  void _setPadMode(OnScreenPadMode mode) {
    setState(() => _padMode = mode);
    AppPrefs.setOnScreenPadMode(mode);
  }

  void _setActionButton(String button, int? scancode) {
    setState(() {
      if (button == 'a') {
        _buttonA = scancode;
      } else {
        _buttonB = scancode;
      }
    });
    AppPrefs.setActionButtonScancode(button, scancode);
  }

  void _setCustomButtons(List<int> scancodes) {
    setState(() => _customButtons = scancodes);
    AppPrefs.setCustomButtons(scancodes);
  }

  Future<void> _pickActionButtonKey(String button) async {
    final key = await showDosKeyPicker(context);
    if (key == null) return;
    _setActionButton(button, key.scancode);
  }

  Future<void> _addCustomButton() async {
    final key = await showDosKeyPicker(context);
    if (key == null) return;
    _setCustomButtons([..._customButtons, key.scancode]);
  }

  /// Taps the key on the running machine briefly so the user can confirm a
  /// binding does what they expect. Harmless when no core is running: the
  /// bridge drops key events in that case.
  Future<void> _testKey(int scancode) async {
    widget.core.keyEvent(scancode, true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    widget.core.keyEvent(scancode, false);
  }

  Widget _card({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: RetroDosboxColors.cardFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: RetroDosboxColors.cardStroke),
        ),
        child: child,
      ),
    );
  }

  Widget _actionButtonRow(String button, int? scancode) {
    final label = scancode == null
        ? 'Default joystick button'
        : RetroDosboxKeyCatalogue.labelFor(scancode);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(button.toUpperCase(),
                style: const TextStyle(
                    color: RetroDosboxColors.accentAmber,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          TextButton(
            onPressed: () => _pickActionButtonKey(button),
            child: const Text('Change key',
                style: TextStyle(color: RetroDosboxColors.accentTeal)),
          ),
          // Only offered when a key is bound: with no binding there is
          // nothing to reset to, and a live-but-inert button is confusing.
          if (scancode != null)
            TextButton(
              onPressed: () => _setActionButton(button, null),
              child: const Text('Reset',
                  style: TextStyle(color: RetroDosboxColors.textMuted)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: RetroDosboxColors.accentAmber));
    }

    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Input Settings',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
        ),
        // The joystick switch is first because it decides what every other
        // control on this screen actually sends.
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Emulated PC joystick',
                            style: TextStyle(
                                color: Colors.white, fontSize: 14)),
                        SizedBox(height: 4),
                        Text(
                          'Off by default, and that is deliberate. Most DOS '
                          'games are keyboard-only and never read the game '
                          'port; the ones that do usually need calibrating '
                          'in their own setup program first. With this off, '
                          'the on-screen pad and any external controller '
                          'send keys instead, which is what the majority of '
                          'titles want. Turn it on for a game you know has '
                          'joystick support.',
                          style: TextStyle(
                              color: RetroDosboxColors.textMuted2, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _joystickEnabled,
                    activeThumbColor: RetroDosboxColors.accentAmber,
                    onChanged: _setJoystickEnabled,
                  ),
                ],
              ),
            ],
          ),
        ),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('On-screen pad',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 8),
              // Horizontally scrollable so the segments size to their text.
              // Given a narrow panel SegmentedButton divides the width evenly
              // and lets each label WRAP, which on an iPhone rendered "Always"
              // as "Alwa/ys" and "Never" as "Neve/r" -- unreadable, and in
              // every screenshot of this screen. Unbounded width makes each
              // segment take what it needs; the scroll only engages when the
              // row genuinely does not fit.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<OnScreenPadMode>(
                  // Sized to fit the narrowest panel this screen has. At the
                  // default size three labels do not fit an iPhone's content
                  // column, and the row is then clipped at the edge -- which
                  // hides the third choice rather than merely tightening it.
                  style: SegmentedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    for (final mode in OnScreenPadMode.values)
                      ButtonSegment(
                          value: mode,
                          label: Text(mode.label, maxLines: 1)),
                  ],
                  selected: {_padMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => _setPadMode(s.first),
                ),
              ),
              const SizedBox(height: 8),
              // The description comes from the enum rather than being
              // repeated here, so the wording cannot drift from the value the
              // emulator screen acts on.
              Text(_padMode.description,
                  style: const TextStyle(
                      color: RetroDosboxColors.textMuted2, fontSize: 12)),
            ],
          ),
        ),
        _card(
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Left-handed mode',
                        style:
                            TextStyle(color: Colors.white, fontSize: 14)),
                    SizedBox(height: 4),
                    Text(
                      'Moves the on-screen joystick to the bottom-right and '
                      'the action buttons to the bottom-left. Direction '
                      'mapping is unchanged.',
                      style: TextStyle(
                          color: RetroDosboxColors.textMuted2, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _leftHanded,
                activeThumbColor: RetroDosboxColors.accentAmber,
                onChanged: _setLeftHanded,
              ),
            ],
          ),
        ),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Action buttons',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 4),
              const Text(
                'A and B fire the emulated joystick by default. Bind either '
                'of them to a keyboard key for the many games that expect '
                'Ctrl, Alt or Space as their fire button.',
                style: TextStyle(color: RetroDosboxColors.textMuted2, fontSize: 12),
              ),
              _actionButtonRow('a', _buttonA),
              _actionButtonRow('b', _buttonB),
            ],
          ),
        ),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Extra on-screen buttons',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 4),
              const Text(
                'Additional touch buttons, each sending one key press. Useful '
                'for the keys DOS games ask for constantly -- Esc to skip a '
                'cutscene, F2 to save, a keypad key to steer. Tap a button '
                'here to send a test press to the running game.',
                style: TextStyle(color: RetroDosboxColors.textMuted2, fontSize: 12),
              ),
              const SizedBox(height: 10),
              if (_customButtons.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No extra buttons yet.',
                      style:
                          TextStyle(color: RetroDosboxColors.textMuted, fontSize: 12)),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (int i = 0; i < _customButtons.length; i++)
                      InputChip(
                        label: Text(RetroDosboxKeyCatalogue.labelFor(
                            _customButtons[i])),
                        backgroundColor: RetroDosboxColors.coverFill,
                        labelStyle: const TextStyle(color: Colors.white),
                        deleteIconColor: RetroDosboxColors.textMuted,
                        onPressed: () => _testKey(_customButtons[i]),
                        onDeleted: () {
                          // Index-based removal, not value-based: the same
                          // key may legitimately be added twice and removing
                          // by value would delete the wrong chip.
                          final next = [..._customButtons]..removeAt(i);
                          _setCustomButtons(next);
                        },
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add button'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: RetroDosboxColors.accentTeal,
                    side: const BorderSide(color: RetroDosboxColors.accentTeal),
                  ),
                  onPressed: _addCustomButton,
                ),
              ),
            ],
          ),
        ),
        _card(
          child: Row(
            children: [
              Icon(
                widget.controllerConnected
                    ? Icons.sports_esports
                    : Icons.sports_esports_outlined,
                color: widget.controllerConnected
                    ? RetroDosboxColors.accentTeal
                    : RetroDosboxColors.textMuted,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('External controller',
                        style:
                            TextStyle(color: Colors.white, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(
                      widget.controllerConnected
                          ? 'Connected. Its stick and buttons follow the '
                              'settings above, and the on-screen pad follows '
                              'the "On-screen pad" mode.'
                          : 'None detected. Plug one in at any time -- no '
                              'restart needed.',
                      style: const TextStyle(
                          color: RetroDosboxColors.textMuted2, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
