
// The touch gestures, pinned.
//
// Worth testing precisely because this logic fails quietly: a tap slop too
// tight means taps are never recognised and look like a dead button, and a
// second finger that also emits a click looks like a bug in the mouse rather
// than in the gesture. Every case below is one a device actually produced at
// some point -- here or on the Amiga front end this grammar came from.
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_dosbox/data/touch_pointer_gestures.dart';

void main() {
  late TouchPointerGestures g;
  setUp(() => g = TouchPointerGestures());

  const nudge = Offset(1, 1); // inside the slop
  const drag = Offset(40, 30); // well outside it

  group('one finger', () {
    test('landing does nothing on its own', () {
      // It might become a drag, a tap or a hold; the pointer must not twitch
      // and no button may be pressed until we know which.
      expect(g.onDown(1), TouchAction.none);
    });

    test('sliding moves the pointer', () {
      g.onDown(1);
      expect(g.onMove(drag), TouchAction.move);
    });

    test('a tap clicks on release', () {
      g.onDown(1);
      expect(g.onUp(0), TouchAction.leftClick);
    });

    test('a wobble is still a tap', () {
      // A finger never lands and lifts on one pixel. Demanding that would
      // mean a tap was only ever recognised by accident.
      g.onDown(1);
      g.onMove(nudge);
      expect(g.onUp(0), TouchAction.leftClick);
    });

    test('a drag does NOT click on release', () {
      // This is the selection-box bug: moving the pointer must never also
      // press the button.
      g.onDown(1);
      g.onMove(drag);
      expect(g.onUp(0), TouchAction.none);
    });

    test('two taps are two clicks, so Windows can see a double click', () {
      // Deliberately NOT synthesised here. Emitting one click for a detected
      // double tap meant an icon could be selected but never opened.
      g.onDown(1);
      expect(g.onUp(0), TouchAction.leftClick);
      g.onDown(1);
      expect(g.onUp(0), TouchAction.leftClick);
    });
  });

  group('hold-still right click', () {
    test('a still finger right-clicks when the hold expires', () {
      g.onDown(1);
      expect(g.onHoldExpired(), TouchAction.rightClick);
    });

    test('lifting after the hold is NOT also a left click', () {
      // The left click on the lift dismissed whatever the right click had
      // just opened -- which read as the right click not working at all.
      g.onDown(1);
      g.onHoldExpired();
      expect(g.onUp(0), TouchAction.none);
    });

    test('a drag disarms the hold', () {
      g.onDown(1);
      g.onMove(drag);
      expect(g.holdArmed, isFalse);
      expect(g.onHoldExpired(), TouchAction.none);
    });

    test('a wobble does not disarm it', () {
      g.onDown(1);
      g.onMove(nudge);
      expect(g.holdArmed, isTrue);
      expect(g.onHoldExpired(), TouchAction.rightClick);
    });

    test('a second finger disarms the hold', () {
      // Two fingers is a held drag, not a press-and-wait.
      g.onDown(1);
      g.onDown(2);
      expect(g.holdArmed, isFalse);
      expect(g.onHoldExpired(), TouchAction.none);
    });
  });

  group('second finger holds the button', () {
    test('landing presses and holds', () {
      g.onDown(1);
      expect(g.onDown(2), TouchAction.leftDown);
    });

    test('moving with the button held still moves -- the drag itself', () {
      g.onDown(1);
      g.onDown(2);
      expect(g.onMove(drag), TouchAction.move);
    });

    test('the second finger lifting is the drop', () {
      g.onDown(1);
      g.onDown(2);
      expect(g.onUp(1), TouchAction.leftUp);
      // The remaining finger lifting afterwards is nothing: the touch was a
      // drag, not a tap.
      expect(g.onUp(0), TouchAction.none);
    });

    test('lifting both at once still releases the button exactly once', () {
      // Releasing on ANY finger going -- rather than only the second --
      // means the guest can never be left holding a button with nothing to
      // release it.
      g.onDown(1);
      g.onDown(2);
      expect(g.onUp(1), TouchAction.leftUp);
      expect(g.onUp(0), TouchAction.none);
    });

    test('a third finger does not press again', () {
      g.onDown(1);
      g.onDown(2);
      expect(g.onDown(3), TouchAction.none);
    });

    test('the next touch after a drag-and-drop is a fresh tap', () {
      g.onDown(1);
      g.onDown(2);
      g.onUp(1);
      g.onUp(0);
      g.onDown(1);
      expect(g.onUp(0), TouchAction.leftClick);
    });
  });
}
