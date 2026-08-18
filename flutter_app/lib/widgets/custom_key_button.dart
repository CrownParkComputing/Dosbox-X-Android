import 'package:flutter/material.dart';

import '../data/dos_scancodes.dart';
import '../ffi/dosbox_core.dart';
import '../theme/dosbox_theme.dart';

/// An extra on-screen button the user added themselves, bound to one
/// keyboard key.
///
/// Deliberately NOT a remap of an existing control: the joystick stays the
/// joystick and the action buttons stay action buttons, and these are added
/// explicitly from Input settings ("Add button" -> pick a key). Presses go
/// straight to [DosboxCore.keyEvent] as an SDL scancode, so any key in
/// [DosKeyCatalogue] works -- including the keypad and the modifiers, which
/// is what DOS games actually ask for far more often than a game-port
/// button.
class CustomKeyButton extends StatefulWidget {
  final DosKey dosKey;
  final DosboxCore core;
  final double size;

  const CustomKeyButton({
    super.key,
    required this.dosKey,
    required this.core,
    this.size = 52,
  });

  @override
  State<CustomKeyButton> createState() => _CustomKeyButtonState();
}

class _CustomKeyButtonState extends State<CustomKeyButton> {
  bool _pressed = false;

  void _down() {
    setState(() => _pressed = true);
    widget.core.keyEvent(widget.dosKey.scancode, true);
  }

  void _up() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.core.keyEvent(widget.dosKey.scancode, false);
  }

  @override
  void dispose() {
    // A button removed (or a screen left) while held must not leave the key
    // stuck down: DOS keyboard state lives in the emulated BIOS and nothing
    // else will ever send the matching key-up, so the game would keep
    // repeating the key indefinitely.
    if (_pressed) {
      widget.core.keyEvent(widget.dosKey.scancode, false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _down(),
      onTapUp: (_) => _up(),
      onTapCancel: _up,
      child: Container(
        constraints: BoxConstraints(minWidth: widget.size),
        height: widget.size,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.size / 2),
          gradient: RadialGradient(
            center: const Alignment(-0.3, -0.3),
            colors: _pressed
                ? [const Color(0xFF34D9C4), const Color(0xFF1B8A7D)]
                : [
                    Colors.white.withValues(alpha: 0.30),
                    const Color(0x665F6670),
                  ],
          ),
          border: Border.all(
            color: _pressed ? Colors.white : const Color(0x99D6DADF),
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          widget.dosKey.label,
          maxLines: 1,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// Modal that lets the user pick which key a new button should send.
/// Grouped by [DosKeyCatalogue.groups] so the whole PC keyboard -- letters,
/// number row, function keys, the keypad -- is browsable instead of being one
/// undifferentiated grid of a hundred-odd caps.
Future<DosKey?> showDosKeyPicker(BuildContext context) {
  return showDialog<DosKey>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: const Color(0xFF141A1F),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Choose a key for the new button',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  for (final entry in DosKeyCatalogue.groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 6),
                      child: Text(
                        entry.key.toUpperCase(),
                        style: const TextStyle(
                            color: DosColors.accentAmber,
                            fontSize: 11,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final key in entry.value)
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(key),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Color(0xFF3D4652)),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              minimumSize: Size.zero,
                            ),
                            child: Text(key.label),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 12, 8),
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
