// What a touch on the emulated screen means.
//
//   one finger, sliding   -> move the pointer BY that much
//   one finger, tap       -> left click, where the pointer is
//   two fingers, tap      -> right click, where the pointer is
//
// There is deliberately no double-tap rule. A tap IS a click, so two quick
// taps are two quick clicks, and Windows decides for itself whether that was
// a double click using its own double-click time -- exactly as it would with
// a real mouse. Detecting the double tap here and emitting a single click
// from it meant an icon could be selected but never opened.
//
// Movement is relative: the pointer follows the finger rather than jumping to
// it. Jumping needs the pointer put at an absolute position, and a PS/2 mouse
// cannot be told where to be -- it only reports movement. Placing it meant
// pinning it against a corner, then guessing how far it had really travelled
// afterwards, and the guess was wrong every time because the guest applies
// its own pointer speed on top. The error compounded and the pointer jumped
// around. Relative movement has no such state to get wrong: drag until it is
// where you want it, and every drag is as accurate as the last.
//
// Kept out of the widget because the widget is the one place it cannot be
// tested, and this is exactly the kind of logic that fails quietly.
import 'dart:ui' show Offset;

/// What the caller should do about a touch.
enum TouchAction {
  /// Nothing.
  none,

  /// Move the pointer by the reported amount.
  move,

  /// Click the left button where the pointer already is.
  leftClick,

  /// Click the right button where the pointer already is. Deliberately does
  /// NOT move: a right click is aimed at what is already under the pointer,
  /// and moving first would put the menu somewhere else.
  rightClick,
}

class TouchPointerGestures {
  /// How far a finger may travel and still count as a tap rather than a drag,
  /// in emulated pixels.
  ///
  /// A finger never lands and lifts on exactly one pixel, so zero would mean
  /// a tap was only ever recognised by accident. Generous enough to forgive a
  /// wobble, small enough that a deliberate drag is never taken for a tap.
  static const double tapSlopPixels = 6;

  /// True once a second finger has landed, until every finger is lifted.
  ///
  /// Without this the second finger's own events are read as a fresh
  /// one-finger gesture, so a right click would also drag the pointer and
  /// then emit a left click on release.
  bool _multiTouch = false;

  /// Whether the current one-finger touch has moved far enough to be a drag.
  bool _dragged = false;

  /// Total travel of the current touch, for the slop test.
  Offset _travel = Offset.zero;

  /// A finger landed. [pointers] is how many are now down.
  TouchAction onDown(int pointers) {
    if (pointers >= 2) {
      _multiTouch = true;
      // The finger already down was a tap in waiting. It is not one now: the
      // user asked for a right click, and lifting must not also left click.
      _dragged = true;
      return TouchAction.rightClick;
    }
    if (_multiTouch) return TouchAction.none;

    _dragged = false;
    _travel = Offset.zero;
    return TouchAction.none;
  }

  /// A finger slid by [deltaEmulatedPixels].
  TouchAction onMove(Offset deltaEmulatedPixels) {
    if (_multiTouch) return TouchAction.none;
    _travel += deltaEmulatedPixels;
    if (_travel.distance > tapSlopPixels) _dragged = true;
    return TouchAction.move;
  }

  /// A finger lifted. [pointers] is how many remain down.
  ///
  /// The click happens HERE, on the way up, and only for a one-finger touch
  /// that never became a drag. Clicking on the way down is what pressed the
  /// button before the pointer had settled and dragged selection boxes across
  /// the desktop.
  TouchAction onUp(int pointers) {
    final wasTap = !_multiTouch && !_dragged;
    if (pointers == 0) {
      _multiTouch = false;
      _dragged = false;
      _travel = Offset.zero;
    }
    return wasTap ? TouchAction.leftClick : TouchAction.none;
  }
}
