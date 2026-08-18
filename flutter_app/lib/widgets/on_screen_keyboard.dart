import 'package:flutter/material.dart';

import '../data/dos_scancodes.dart';
import '../theme/dosbox_theme.dart';

/// A full PC keyboard, drawn across the bottom of the emulator screen.
///
/// The strip of five keys this replaces was fine for a game whose whole
/// control set is Esc/Enter/Space, and useless for anything that wants F-keys,
/// a name typed into a high-score table, or the ~ console. DOS software
/// assumes a real keyboard exists, so on a tablet one has to be drawn.
///
/// Keys send scancodes, not characters, for the same reason the FFI layer
/// does: DOS games read the keyboard at the scancode level, and a
/// character-based API cannot express a held arrow key or tell the two Alt
/// keys apart.
///
/// Modifiers latch rather than repeat: touch has no way to hold Ctrl while
/// pressing C, so tapping Ctrl arms it, the next key press sends
/// Ctrl-down/key/Ctrl-up, and the modifier clears. Tapping it twice locks it
/// on, which is what a game wanting Ctrl held for "fire" needs.
class OnScreenKeyboard extends StatefulWidget {
  const OnScreenKeyboard({
    super.key,
    required this.onKey,
    this.extraKeys = const <int>[],
  });

  /// Called with (scancode, pressed) -- both edges, so a held key works.
  final void Function(int scancode, bool pressed) onKey;

  /// The user's own chosen keys, appended to the function row. Keeps the
  /// existing "custom buttons" feature working now that the strip is gone.
  final List<int> extraKeys;

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _Key {
  const _Key(this.label, this.scancode, {this.flex = 2});

  /// Null scancode = a spacer, so a row can be padded without a tappable gap.
  final String label;
  final int? scancode;
  final int flex;
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  /// Modifiers currently armed (one-shot) or locked.
  final Set<int> _armed = <int>{};
  final Set<int> _locked = <int>{};

  static const _modifiers = {
    DosScancode.lctrl,
    DosScancode.lalt,
    DosScancode.lshift,
  };

  List<List<_Key>> get _rows => [
        const [
          _Key('Esc', DosScancode.escape),
          _Key('F1', DosScancode.f1),
          _Key('F2', DosScancode.f2),
          _Key('F3', DosScancode.f3),
          _Key('F4', DosScancode.f4),
          _Key('F5', DosScancode.f5),
          _Key('F6', DosScancode.f6),
          _Key('F7', DosScancode.f7),
          _Key('F8', DosScancode.f8),
          _Key('F9', DosScancode.f9),
          _Key('F10', DosScancode.f10),
          _Key('F11', DosScancode.f11),
          _Key('F12', DosScancode.f12),
        ],
        const [
          _Key('`', DosScancode.grave),
          _Key('1', DosScancode.n1),
          _Key('2', DosScancode.n2),
          _Key('3', DosScancode.n3),
          _Key('4', DosScancode.n4),
          _Key('5', DosScancode.n5),
          _Key('6', DosScancode.n6),
          _Key('7', DosScancode.n7),
          _Key('8', DosScancode.n8),
          _Key('9', DosScancode.n9),
          _Key('0', DosScancode.n0),
          _Key('-', DosScancode.minus),
          _Key('=', DosScancode.equals),
          _Key('Bksp', DosScancode.backspace, flex: 3),
        ],
        const [
          _Key('Tab', DosScancode.tab, flex: 3),
          _Key('Q', DosScancode.q),
          _Key('W', DosScancode.w),
          _Key('E', DosScancode.e),
          _Key('R', DosScancode.r),
          _Key('T', DosScancode.t),
          _Key('Y', DosScancode.y),
          _Key('U', DosScancode.u),
          _Key('I', DosScancode.i),
          _Key('O', DosScancode.o),
          _Key('P', DosScancode.p),
          _Key('[', DosScancode.leftBracket),
          _Key(']', DosScancode.rightBracket),
          _Key(r'\', DosScancode.backslash),
        ],
        const [
          _Key('Caps', DosScancode.capsLock, flex: 3),
          _Key('A', DosScancode.a),
          _Key('S', DosScancode.s),
          _Key('D', DosScancode.d),
          _Key('F', DosScancode.f),
          _Key('G', DosScancode.g),
          _Key('H', DosScancode.h),
          _Key('J', DosScancode.j),
          _Key('K', DosScancode.k),
          _Key('L', DosScancode.l),
          _Key(';', DosScancode.semicolon),
          _Key("'", DosScancode.apostrophe),
          _Key('Enter', DosScancode.enter, flex: 4),
        ],
        const [
          _Key('Shift', DosScancode.lshift, flex: 4),
          _Key('Z', DosScancode.z),
          _Key('X', DosScancode.x),
          _Key('C', DosScancode.c),
          _Key('V', DosScancode.v),
          _Key('B', DosScancode.b),
          _Key('N', DosScancode.n),
          _Key('M', DosScancode.m),
          _Key(',', DosScancode.comma),
          _Key('.', DosScancode.period),
          _Key('/', DosScancode.slash),
          _Key('↑', DosScancode.up),
          _Key('PgUp', DosScancode.pageUp, flex: 3),
        ],
        const [
          _Key('Ctrl', DosScancode.lctrl, flex: 3),
          _Key('Alt', DosScancode.lalt, flex: 3),
          _Key('Space', DosScancode.space, flex: 10),
          _Key('←', DosScancode.left),
          _Key('↓', DosScancode.down),
          _Key('→', DosScancode.right),
          _Key('PgDn', DosScancode.pageDown, flex: 3),
        ],
      ];

  void _tap(int scancode) {
    if (_modifiers.contains(scancode)) {
      setState(() {
        // Tap once to arm for the next key, twice to lock it down.
        if (_locked.contains(scancode)) {
          _locked.remove(scancode);
          _armed.remove(scancode);
          widget.onKey(scancode, false);
        } else if (_armed.contains(scancode)) {
          _armed.remove(scancode);
          _locked.add(scancode);
          widget.onKey(scancode, true);
        } else {
          _armed.add(scancode);
        }
      });
      return;
    }

    // Armed modifiers wrap this key press; locked ones are already held down
    // and stay that way.
    final wrapping = _armed.toList();
    for (final m in wrapping) {
      widget.onKey(m, true);
    }
    widget.onKey(scancode, true);
    widget.onKey(scancode, false);
    for (final m in wrapping) {
      widget.onKey(m, false);
    }
    if (wrapping.isNotEmpty) {
      setState(_armed.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final extras = widget.extraKeys;

    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  for (final key in row)
                    Expanded(
                      flex: key.flex,
                      child: _KeyCap(
                        label: key.label,
                        active: key.scancode != null &&
                            (_armed.contains(key.scancode) ||
                                _locked.contains(key.scancode)),
                        locked: key.scancode != null &&
                            _locked.contains(key.scancode),
                        onTap: key.scancode == null
                            ? null
                            : () => _tap(key.scancode!),
                      ),
                    ),
                ],
              ),
            ),
          if (extras.isNotEmpty)
            Row(
              children: [
                for (final code in extras)
                  Expanded(
                    child: _KeyCap(
                      label: DosKeyCatalogue.labelFor(code),
                      active: false,
                      locked: false,
                      onTap: () => _tap(code),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.label,
    required this.active,
    required this.locked,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool locked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? DosColors.selectedFill : DosColors.panelFill,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                // A locked modifier is drawn differently from an armed one:
                // "Ctrl is held down" and "Ctrl applies to the next key" are
                // different states and the player has to be able to tell.
                color: locked
                    ? DosColors.accentAmber
                    : active
                        ? DosColors.selectedStroke
                        : DosColors.panelStroke,
                width: locked ? 2 : 1,
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DosColors.sidebarLabelSelected,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
