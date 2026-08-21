import 'package:flutter/material.dart';

import '../data/retrodosbox_scancodes.dart';
import '../theme/retrodosbox_theme.dart';

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
    RetroDosboxScancode.lctrl,
    RetroDosboxScancode.lalt,
    RetroDosboxScancode.lshift,
  };

  List<List<_Key>> get _rows => [
        const [
          _Key('Esc', RetroDosboxScancode.escape),
          _Key('F1', RetroDosboxScancode.f1),
          _Key('F2', RetroDosboxScancode.f2),
          _Key('F3', RetroDosboxScancode.f3),
          _Key('F4', RetroDosboxScancode.f4),
          _Key('F5', RetroDosboxScancode.f5),
          _Key('F6', RetroDosboxScancode.f6),
          _Key('F7', RetroDosboxScancode.f7),
          _Key('F8', RetroDosboxScancode.f8),
          _Key('F9', RetroDosboxScancode.f9),
          _Key('F10', RetroDosboxScancode.f10),
          _Key('F11', RetroDosboxScancode.f11),
          _Key('F12', RetroDosboxScancode.f12),
        ],
        const [
          _Key('`', RetroDosboxScancode.grave),
          _Key('1', RetroDosboxScancode.n1),
          _Key('2', RetroDosboxScancode.n2),
          _Key('3', RetroDosboxScancode.n3),
          _Key('4', RetroDosboxScancode.n4),
          _Key('5', RetroDosboxScancode.n5),
          _Key('6', RetroDosboxScancode.n6),
          _Key('7', RetroDosboxScancode.n7),
          _Key('8', RetroDosboxScancode.n8),
          _Key('9', RetroDosboxScancode.n9),
          _Key('0', RetroDosboxScancode.n0),
          _Key('-', RetroDosboxScancode.minus),
          _Key('=', RetroDosboxScancode.equals),
          _Key('Bksp', RetroDosboxScancode.backspace, flex: 3),
        ],
        const [
          _Key('Tab', RetroDosboxScancode.tab, flex: 3),
          _Key('Q', RetroDosboxScancode.q),
          _Key('W', RetroDosboxScancode.w),
          _Key('E', RetroDosboxScancode.e),
          _Key('R', RetroDosboxScancode.r),
          _Key('T', RetroDosboxScancode.t),
          _Key('Y', RetroDosboxScancode.y),
          _Key('U', RetroDosboxScancode.u),
          _Key('I', RetroDosboxScancode.i),
          _Key('O', RetroDosboxScancode.o),
          _Key('P', RetroDosboxScancode.p),
          _Key('[', RetroDosboxScancode.leftBracket),
          _Key(']', RetroDosboxScancode.rightBracket),
          _Key(r'\', RetroDosboxScancode.backslash),
        ],
        const [
          _Key('Caps', RetroDosboxScancode.capsLock, flex: 3),
          _Key('A', RetroDosboxScancode.a),
          _Key('S', RetroDosboxScancode.s),
          _Key('D', RetroDosboxScancode.d),
          _Key('F', RetroDosboxScancode.f),
          _Key('G', RetroDosboxScancode.g),
          _Key('H', RetroDosboxScancode.h),
          _Key('J', RetroDosboxScancode.j),
          _Key('K', RetroDosboxScancode.k),
          _Key('L', RetroDosboxScancode.l),
          _Key(';', RetroDosboxScancode.semicolon),
          _Key("'", RetroDosboxScancode.apostrophe),
          _Key('Enter', RetroDosboxScancode.enter, flex: 4),
        ],
        const [
          _Key('Shift', RetroDosboxScancode.lshift, flex: 4),
          _Key('Z', RetroDosboxScancode.z),
          _Key('X', RetroDosboxScancode.x),
          _Key('C', RetroDosboxScancode.c),
          _Key('V', RetroDosboxScancode.v),
          _Key('B', RetroDosboxScancode.b),
          _Key('N', RetroDosboxScancode.n),
          _Key('M', RetroDosboxScancode.m),
          _Key(',', RetroDosboxScancode.comma),
          _Key('.', RetroDosboxScancode.period),
          _Key('/', RetroDosboxScancode.slash),
          _Key('↑', RetroDosboxScancode.up),
          _Key('PgUp', RetroDosboxScancode.pageUp, flex: 3),
        ],
        const [
          _Key('Ctrl', RetroDosboxScancode.lctrl, flex: 3),
          _Key('Alt', RetroDosboxScancode.lalt, flex: 3),
          _Key('Space', RetroDosboxScancode.space, flex: 10),
          _Key('←', RetroDosboxScancode.left),
          _Key('↓', RetroDosboxScancode.down),
          _Key('→', RetroDosboxScancode.right),
          _Key('PgDn', RetroDosboxScancode.pageDown, flex: 3),
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

    // The outer Material gives the whole keyboard a stable surface for hit
    // testing. Without it the translucent Container can sit between a tap
    // and the InkWells inside the keys under unusual Stack layouts, with
    // the InkWell then registering on the picture's GestureDetector (mouse
    // mode) rather than the keyboard itself. The Material here is in
    // addition to -- not instead of -- the per-key Material each _KeyCap
    // owns for its ripple.
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      child: Container(
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
                      label: RetroDosboxKeyCatalogue.labelFor(code),
                      active: false,
                      locked: false,
                      onTap: () => _tap(code),
                    ),
                  ),
              ],
            ),
          ],
        ),
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
        color: active ? RetroDosboxColors.selectedFill : RetroDosboxColors.panelFill,
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
                    ? RetroDosboxColors.accentAmber
                    : active
                        ? RetroDosboxColors.selectedStroke
                        : RetroDosboxColors.panelStroke,
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
                    color: RetroDosboxColors.sidebarLabelSelected,
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
