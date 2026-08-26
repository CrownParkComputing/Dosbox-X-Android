// The touch gestures, pinned.
//
// Worth testing precisely because this logic fails quietly: a tap slop too
// tight means taps are never recognised and look like a dead button, and a
// two-finger tap that also emits a left click looks like a bug in the mouse
// rather than in the gesture. Every case below is one the device actually
// produced at some point.
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_dosbox/data/touch_pointer_gestures.dart';

void main() {
  late TouchPointerGestures g;
  setUp(() => g = TouchPointerGestures());

  const still = Offset.zero;
  const nudge = Offset(1, 1); // inside the slop
  const drag = Offset(40, 30); // well outside it

  group('one finger', () {
    test('landing does nothing on its own', () {
      // It might become a drag or a tap; the pointer must not twitch and no
      // button may be pressed until we know which.
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

    test('slop accumulates, so a slow drag is still a drag', () {
      // Many small moves that individually sit inside the slop must still add
      // up to a drag, or a careful slow drag would end in a stray click.
      g.onDown(1);
      for (var i = 0; i < 12; i++) {
        g.onMove(nudge);
      }
      expect(g.onUp(0), TouchAction.none);
    });
  });

  group('two fingers', () {
    test('right clicks as the second finger lands', () {
      g.onDown(1);
      expect(g.onDown(2), TouchAction.rightClick);
    });

    test('does not move the pointer', () {
      g.onDown(1);
      expect(g.onDown(2), isNot(TouchAction.move));
    });

    test('lifting the fingers does not also left click', () {
      // The finger already down was a tap in waiting; the right click has to
      // cancel it or every right click would be followed by a left one.
      g.onDown(1);
      g.onDown(2);
      expect(g.onUp(1), TouchAction.none);
      expect(g.onUp(0), TouchAction.none);
    });

    test('the second finger sliding does not move the pointer', () {
      g.onDown(1);
      g.onDown(2);
      expect(g.onMove(drag), TouchAction.none);
    });

    test('once every finger is up, one-finger gestures work again', () {
      g.onDown(1);
      g.onDown(2);
      g.onUp(1);
      g.onUp(0);
      g.onDown(1);
      expect(g.onMove(drag), TouchAction.move);
      expect(g.onUp(0), TouchAction.none, reason: 'that was a drag');
    });

    test('and a tap still clicks afterwards', () {
      g.onDown(1);
      g.onDown(2);
      g.onUp(1);
      g.onUp(0);
      g.onDown(1);
      expect(g.onUp(0), TouchAction.leftClick);
    });
  });

  test('perfectly still is a tap, not a drag', () {
    g.onDown(1);
    g.onMove(still);
    expect(g.onUp(0), TouchAction.leftClick);
  });
}
