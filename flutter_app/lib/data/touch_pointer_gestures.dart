// What a touch on the emulated screen means.
//
// The grammar, borrowed from every laptop trackpad -- and from the Retro-*
// family's Amiga front end, where Workbench proved it out:
//
//   one finger, sliding      -> move the pointer BY that much
//   one finger, tap          -> left click, where the pointer is
//   a second finger DOWN     -> the left button goes down and STAYS down
//   the second finger UP     -> the button releases -- the drop
//   press and hold still     -> right click, where the pointer is
//
// The held button is the whole point of the second finger: dragging a
// window, lassoing a selection, pulling a scrollbar -- all of it is
// hold-and-move, and with only tap and click available none of it could be
// done at all. (The second finger used to mean "right click", which spent
// the one gesture that can hold a button on something a hold-still does
// better.)
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
// tested, and this is exactly the kind of logic that fails quietly. Time is
// kept out too: the WIDGET owns the hold timer and reports its expiry via
// [onHoldExpired], so every rule here stays synchronous and pinnable.
import 'dart:ui' show Offset;

/// What the caller should do about a touch.
enum TouchAction {
  /// Nothing.
  none,

  /// Move the pointer by the reported amount.
  move,

  /// Click the left button where the pointer already is.
  leftClick,

  /// Press the left button and LEAVE it pressed -- the start of a drag.
  leftDown,

  /// Release the held left button -- the drop.
  leftUp,

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

  /// How long a finger has to sit still before the hold reads as a right
  /// click. The widget owns the actual timer; this is the duration it arms
  /// it with.
  static const Duration holdDuration = Duration(milliseconds: 550);

  /// True while the second finger holds the left button down.
  bool _lmbHeld = false;

  /// True once the hold-still right click has fired for this touch, so the
  /// first finger lifting afterwards is NOT also a left click -- a left
  /// click on the lift dismissed whatever the right click had just opened,
  /// which read as the right click not working at all.
  bool _holdFired = false;

  /// Whether the current touch has moved far enough to be a drag.
  bool _dragged = false;

  /// Total travel of the current touch, for the slop test.
  Offset _travel = Offset.zero;

  /// Whether the caller's hold timer should currently be running: one still
  /// finger, no button held, no hold fired yet.
  bool get holdArmed => !_dragged && !_lmbHeld && !_holdFired;

  /// A finger landed. [pointers] is how many are now down.
  TouchAction onDown(int pointers) {
    if (pointers >= 2) {
      if (_lmbHeld) return TouchAction.none;
      // The second finger is the button. The finger already down was a tap
      // in waiting; it is not one now -- it is the drag.
      _lmbHeld = true;
      _dragged = true;
      return TouchAction.leftDown;
    }

    _dragged = false;
    _holdFired = false;
    _travel = Offset.zero;
    return TouchAction.none;
  }

  /// A finger slid by [deltaEmulatedPixels].
  ///
  /// The pointer moves whether or not the button is held -- moving WITH the
  /// button held is the drag this grammar exists for.
  TouchAction onMove(Offset deltaEmulatedPixels) {
    _travel += deltaEmulatedPixels;
    if (_travel.distance > tapSlopPixels) _dragged = true;
    return TouchAction.move;
  }

  /// The widget's hold timer expired: the finger has sat still for
  /// [holdDuration]. A right click, unless the touch has since become a
  /// drag or a held drag.
  TouchAction onHoldExpired() {
    if (!holdArmed) return TouchAction.none;
    _holdFired = true;
    return TouchAction.rightClick;
  }

  /// A finger lifted. [pointers] is how many remain down.
  ///
  /// The tap-click happens HERE, on the way up, and only for a touch that
  /// never became a drag or a hold. Clicking on the way down is what pressed
  /// the button before the pointer had settled and dragged selection boxes
  /// across the desktop.
  TouchAction onUp(int pointers) {
    // Any finger lifting releases a held button -- not only the second --
    // so lifting both at once can never leave the guest holding a button
    // with nothing left to release it.
    if (_lmbHeld) {
      _lmbHeld = false;
      if (pointers == 0) _reset();
      return TouchAction.leftUp;
    }
    final wasTap = !_dragged && !_holdFired;
    if (pointers == 0) _reset();
    return wasTap ? TouchAction.leftClick : TouchAction.none;
  }

  void _reset() {
    _lmbHeld = false;
    _dragged = false;
    _holdFired = false;
    _travel = Offset.zero;
  }
}
