// movable_control.dart — An on-screen control the player can drag.
//
// Ported from Retro-C64's _MovableControl, which solves the problem the
// same way: nobody agrees where a joystick belongs, and no default is right
// for both a left-handed player and a right-handed one, so the answer is to
// let them put it where they want and remember.
//
// Positions are fractions of the play area rather than pixels; see
// AppPrefs.getControlPositions for why.
import 'package:flutter/material.dart';

class MovableControl extends StatelessWidget {
  const MovableControl({
    super.key,
    required this.area,
    required this.fraction,
    required this.editing,
    required this.label,
    required this.onMoved,
    required this.onMoveEnd,
    required this.child,
  });

  final Size area;
  final Offset fraction;
  final bool editing;
  final String label;
  final ValueChanged<Offset> onMoved;
  final VoidCallback onMoveEnd;
  final Widget child;

  /// Keeps a control from being dragged so far that its centre leaves the
  /// screen and it can never be grabbed again.
  static const _minFraction = 0.06;
  static const _maxFraction = 0.94;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: fraction.dx * area.width,
      top: fraction.dy * area.height,
      // Positioned from the control's CENTRE, so a stored fraction means
      // the same place regardless of how big the control itself is.
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: editing
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) {
                  if (area.width == 0 || area.height == 0) return;
                  onMoved(Offset(
                    (fraction.dx + d.delta.dx / area.width)
                        .clamp(_minFraction, _maxFraction),
                    (fraction.dy + d.delta.dy / area.height)
                        .clamp(_minFraction, _maxFraction),
                  ));
                },
                onPanEnd: (_) => onMoveEnd(),
                child: _editChrome(child),
              )
            : child,
      ),
    );
  }

  /// While editing, the control is outlined and named -- otherwise a
  /// half-transparent stick on a dark game is something you have to hunt
  /// for before you can move it.
  Widget _editChrome(Widget inner) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF6DD3FF), width: 2),
        borderRadius: BorderRadius.circular(12),
        color: Colors.black.withValues(alpha: 0.35),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.open_with, size: 12, color: Color(0xFF6DD3FF)),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF6DD3FF),
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // The control itself must not react while it is being dragged,
          // or moving the stick would also be pushing it.
          IgnorePointer(child: inner),
        ],
      ),
    );
  }
}
