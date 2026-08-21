import 'package:flutter/material.dart';

import '../data/retrodosbox_scancodes.dart';
import '../ffi/retrodosbox_core.dart';

/// What an on-screen action button sends when it is pressed.
///
/// A C64 fire button only ever had one thing to send, so the sibling app's
/// version of this widget just reported a bool. On the PC that is not enough:
/// a great many DOS games ignore the game port entirely, or use it for
/// movement while the actions the player needs under a thumb are keys (Ctrl
/// to fire, Space to use, Enter to confirm). Rather than force the user to
/// choose between "a fire button" and "a key button", the binding is part of
/// the button's identity and the press callback carries it, so the emulator
/// screen can route a joystick bit into its OR-ed joystick mask and a
/// scancode straight to [RetroDosboxCore.keyEvent] without keeping a parallel
/// table of which button is which.
sealed class ActionBinding {
  const ActionBinding();

  /// Short text for the button cap when no explicit label is given.
  String get defaultLabel;
}

/// Binds the button to one [RetroDosboxJoyBits] button bit on the emulated game port.
class JoyButtonBinding extends ActionBinding {
  /// One of [RetroDosboxJoyBits.button1] .. [RetroDosboxJoyBits.button4]. A single bit, not a
  /// mask: the caller ORs these together itself, and a two-bit "button" would
  /// make releasing one of them ambiguous.
  final int bit;

  const JoyButtonBinding(this.bit);

  @override
  String get defaultLabel {
    switch (bit) {
      case RetroDosboxJoyBits.button1:
        return 'A';
      case RetroDosboxJoyBits.button2:
        return 'B';
      case RetroDosboxJoyBits.button3:
        return 'C';
      case RetroDosboxJoyBits.button4:
        return 'D';
      default:
        return '?';
    }
  }
}

/// Binds the button to an SDL scancode, sent with [RetroDosboxCore.keyEvent].
class KeyActionBinding extends ActionBinding {
  final int scancode;

  const KeyActionBinding(this.scancode);

  @override
  String get defaultLabel => RetroDosboxKeyCatalogue.labelFor(scancode);
}

/// One of the on-screen action buttons.
///
/// These are plain action buttons and nothing else. The Android original
/// carried a hidden long-press-to-remap gesture, which was the wrong shape
/// for the job: a remap you have to discover by holding a button is
/// invisible, and it also meant the only way to get a keyboard key on screen
/// was to give up one of your fire buttons. Binding is now an explicit
/// "add a button, choose what it sends" flow in Input settings -- see
/// widgets/custom_key_button.dart for the labelled key variant of the same
/// idea.
class ActionButton extends StatefulWidget {
  /// What this button sends. Also supplies the cap text when [label] is null.
  final ActionBinding binding;

  /// Overrides the cap text. Useful when the player has bound, say, Left Ctrl
  /// but thinks of it as "FIRE".
  final String? label;

  /// Reports this button's own binding going down/up. The emulator screen
  /// ORs joystick bits with the other input sources and sends one joystick
  /// update; key bindings it forwards directly.
  final void Function(ActionBinding binding, bool pressed) onAction;

  final double size;

  const ActionButton({
    super.key,
    required this.binding,
    required this.onAction,
    this.label,
    this.size = 64,
  });

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _pressed = false;

  void _down() {
    setState(() => _pressed = true);
    widget.onAction(widget.binding, true);
  }

  void _up() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.onAction(widget.binding, false);
  }

  @override
  void dispose() {
    // Never leave a button latched on because the screen went away
    // mid-press: a stuck joystick bit is annoying, a stuck Ctrl is worse.
    if (_pressed) widget.onAction(widget.binding, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.label ?? widget.binding.defaultLabel;
    // Key labels ("Space", "Num Enter") are far longer than the single
    // letters a fire button carries, so the cap text shrinks rather than
    // overflowing the circle.
    final fontSize = text.length <= 2
        ? 20.0
        : text.length <= 5
            ? 14.0
            : 11.0;
    return GestureDetector(
      onTapDown: (_) => _down(),
      onTapUp: (_) => _up(),
      onTapCancel: _up,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.3, -0.3),
            colors: _pressed
                ? [const Color(0xFF34D9C4), const Color(0xFF1B8A7D)]
                : [
                    Colors.white.withValues(alpha: 0.35),
                    const Color(0x665F6670),
                  ],
          ),
          border: Border.all(
            color: _pressed ? Colors.white : const Color(0x99D6DADF),
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(4),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
