import 'dart:math';

import 'package:flutter/material.dart';

import '../ffi/retrodosbox_core.dart';

/// A top-down analog-style "wobble" joystick: a circular base with a
/// draggable knob that leans/offsets toward the drag point (clamped to a
/// max travel radius) and springs back to center on release.
///
/// It reports both halves of what [RetroDosboxCore.joystick] takes, in one call:
///
///  - a digital [RetroDosboxJoyBits] mask, discretized into 8 compass sectors with a
///    dead zone (18% of the base radius) near the center. Plenty of DOS games
///    only ever ask the game port "is the stick past the threshold", and the
///    keyboard-emulating mapper profiles need a hard on/off too.
///  - continuous axes in -1..1. Unlike the C64 port this widget was first
///    written for -- which is digital, 8-way and nothing else -- the PC game
///    port really is analog, and flight sims read the raw axis values. Passing
///    only the discretized mask would throw that away, so both go out and the
///    caller decides.
///
/// Both are derived from the same knob offset, so they can never disagree.
class WobbleJoystick extends StatefulWidget {
  /// Called on every change with a [RetroDosboxJoyBits] direction mask (the button
  /// bits are never set here -- fire buttons are separate widgets) and the
  /// stick position as axes in -1..1, y positive downward, matching the
  /// argument shape of [RetroDosboxCore.joystick].
  final void Function(int mask, double axisX, double axisY)? onJoystick;

  final double size;

  const WobbleJoystick({super.key, this.onJoystick, this.size = 140});

  @override
  State<WobbleJoystick> createState() => _WobbleJoystickState();
}

class _WobbleJoystickState extends State<WobbleJoystick>
    with SingleTickerProviderStateMixin {
  // Built in initState rather than as a `late final` initialiser. A lazy
  // one is not created until something first touches it -- and if nothing
  // ever does (the player leaves the game without moving the stick, or the
  // touch controls are hidden again) then dispose() is that first touch,
  // which builds an AnimationController against an element that has already
  // been deactivated and trips a framework assertion on the way out.
  late final AnimationController _springController;
  Animation<Offset>? _springAnim;

  Offset _knobOffset = Offset.zero;
  int _mask = 0;
  double _axisX = 0, _axisY = 0;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _springController.dispose();
    super.dispose();
  }

  bool get _active => _mask != 0;

  void _emit(int mask, double axisX, double axisY) {
    if (mask == _mask && axisX == _axisX && axisY == _axisY) return;
    setState(() {
      _mask = mask;
      _axisX = axisX;
      _axisY = axisY;
    });
    widget.onJoystick?.call(_mask, _axisX, _axisY);
  }

  void _updateFromLocal(Offset local, double radius) {
    _springController.stop();
    final center = Offset(radius, radius);
    var delta = local - center;
    final dist = delta.distance;
    // Knob travel is clamped well inside the base so the ring around it
    // stays visible -- selling the "stick leaning against its base" look.
    final maxTravel = radius * 0.6;
    if (dist > maxTravel) {
      delta = Offset.fromDirection(delta.direction, maxTravel);
    }
    setState(() => _knobOffset = delta);

    // Axes are normalised against the travel limit, not the base radius, so
    // pushing the knob to the edge of its travel really does read as full
    // deflection rather than 60% of it.
    final axisX = (delta.dx / maxTravel).clamp(-1.0, 1.0);
    final axisY = (delta.dy / maxTravel).clamp(-1.0, 1.0);

    final deadZone = radius * 0.18;
    if (dist < deadZone) {
      // Inside the dead zone the axes are reported as centered too: a resting
      // thumb should not trim a flight sim off course.
      _emit(0, 0, 0);
      return;
    }

    // Discretize the drag angle into 8 compass sectors (45 degrees each,
    // centered on the cardinal/diagonal directions) -- diagonals report both
    // adjacent bits, which is exactly what a real 4-switch stick does when
    // pushed into a corner.
    final degrees = (delta.direction * 180 / pi + 360) % 360;
    final sector = ((degrees + 22.5) / 45).floor() % 8;
    // sector 0 = right, going clockwise (screen y grows downward):
    // 0 right, 1 down-right, 2 down, 3 down-left, 4 left, 5 up-left, 6 up, 7 up-right
    const rightSectors = {0, 1, 7};
    const downSectors = {1, 2, 3};
    const leftSectors = {3, 4, 5};
    const upSectors = {5, 6, 7};
    var mask = 0;
    if (upSectors.contains(sector)) mask |= RetroDosboxJoyBits.up;
    if (downSectors.contains(sector)) mask |= RetroDosboxJoyBits.down;
    if (leftSectors.contains(sector)) mask |= RetroDosboxJoyBits.left;
    if (rightSectors.contains(sector)) mask |= RetroDosboxJoyBits.right;
    _emit(mask, axisX, axisY);
  }

  void _release() {
    final begin = _knobOffset;
    _springAnim = Tween<Offset>(begin: begin, end: Offset.zero).animate(
      CurvedAnimation(parent: _springController, curve: Curves.elasticOut),
    )..addListener(() => setState(() => _knobOffset = _springAnim!.value));
    _springController
      ..value = 0
      ..forward();
    // The spring is cosmetic only. Input centres the instant the finger
    // lifts, because an elasticOut overshoot fed to the core as live axis
    // values would make the stick visibly bounce past centre in-game.
    _emit(0, 0, 0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: LayoutBuilder(builder: (context, constraints) {
        final radius = constraints.maxWidth / 2;
        return GestureDetector(
          onPanDown: (d) => _updateFromLocal(d.localPosition, radius),
          onPanUpdate: (d) => _updateFromLocal(d.localPosition, radius),
          onPanEnd: (_) => _release(),
          onPanCancel: _release,
          child: CustomPaint(
            painter: _WobblePainter(knobOffset: _knobOffset, active: _active),
            size: Size(widget.size, widget.size),
          ),
        );
      }),
    );
  }
}

class _WobblePainter extends CustomPainter {
  final Offset knobOffset;
  final bool active;

  _WobblePainter({required this.knobOffset, required this.active});

  static const _baseFill = Color(0x445F6670);
  static const _baseStroke = Color(0x99D6DADF);
  static const _guideStroke = Color(0x33D6DADF);
  static const _knobFillIdle = Color(0xE0C5CBD3);
  static const _knobFillActive = Color(0xFF34D9C4);
  static const _knobStroke = Color(0xEEFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width / 2;
    final strokeWidth = (size.width * 0.02).clamp(2.0, double.infinity);

    // Base ring.
    canvas.drawCircle(
        center, baseRadius - strokeWidth / 2, Paint()..color = _baseFill);
    canvas.drawCircle(
      center,
      baseRadius - strokeWidth / 2,
      Paint()
        ..color = _baseStroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
    // Concentric guide rings so the base reads as an analog stick socket.
    for (final f in [0.35, 0.68]) {
      canvas.drawCircle(
        center,
        baseRadius * f,
        Paint()
          ..color = _guideStroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final knobCenter = center + knobOffset;
    final knobRadius = baseRadius * 0.4;

    // Shadow offset opposite the lean, to fake the stick tilting away from
    // its socket toward the drag direction.
    final shadowOffset = -knobOffset * 0.15;
    canvas.drawCircle(
      knobCenter + shadowOffset + const Offset(0, 3),
      knobRadius * 0.95,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    final knobFill = active ? _knobFillActive : _knobFillIdle;
    final highlightAlign = Alignment(
      (-knobOffset.dx / baseRadius).clamp(-1.0, 1.0) * 0.4 - 0.25,
      (-knobOffset.dy / baseRadius).clamp(-1.0, 1.0) * 0.4 - 0.25,
    );
    final gradient = RadialGradient(
      center: highlightAlign,
      radius: 0.95,
      colors: [Colors.white.withValues(alpha: 0.95), knobFill],
    );
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..shader = gradient.createShader(
            Rect.fromCircle(center: knobCenter, radius: knobRadius)),
    );
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..color = _knobStroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = (size.width * 0.012).clamp(1.5, double.infinity),
    );
  }

  @override
  bool shouldRepaint(covariant _WobblePainter old) =>
      old.knobOffset != knobOffset || old.active != active;
}
