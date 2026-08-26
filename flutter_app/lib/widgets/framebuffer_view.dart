import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ffi/retrodosbox_core.dart';
import '../services/video_settings.dart';

/// Live view of the DOS framebuffer.
///
/// A periodic Timer polls dosbox_core_get_framebuffer(), decodes the copied
/// BGRA8888 bytes into a ui.Image via decodeImageFromPixels, and repaints a
/// CustomPaint. This is not zero-copy -- each decode allocates a new GPU
/// texture -- and the eventual fix is a real Flutter `Texture` widget backed by
/// an external GL/Metal texture the bridge writes into directly. That needs
/// per-platform context-sharing code, so it is deliberately a later milestone;
/// this is the simplest thing that proves the FFI render path end to end.
///
/// Two things it does do properly, both of which matter more for DOS than they
/// did for the C64:
///
///  - It skips the copy and decode entirely when the core's frame counter has
///    not moved. A DOS text-mode prompt can sit on a byte-identical frame for
///    minutes, and decoding 60 of those per second is pure waste.
///  - It uses the aspect ratio DOSBox-X reports for the current video mode
///    rather than assuming 4:3. DOS modes are frequently non-square-pixel
///    (320x200 displayed as 4:3) and frequently not (320x240 displayed
///    square), and there is no single correct constant.
/// Where a finger landed on the picture, as a fraction of the picture in
/// each axis: (0,0) is the top-left of the emulated screen and (1,1) the
/// bottom-right, whatever the picture has been scaled, letterboxed, rotated
/// or bezelled to.
/// A finger sliding. Reports how far it moved, already converted into
/// EMULATED pixels -- only this widget knows the scale between the picture on
/// screen and the guest's own resolution.
typedef FramebufferTouchMove = void Function(Offset deltaEmulatedPixels);

/// A finger landing, with how many are now down on the picture.
///
/// The count is what separates a one-finger tap from a two-finger one, and it
/// has to come from here: the raw Listener is the only thing that sees every
/// pointer, and Flutter's multi-tap gesture recognisers would put the whole
/// arena back in the path this deliberately avoids.
typedef FramebufferTouchDown = void Function(Offset normalized, int pointers);

class FramebufferView extends StatefulWidget {
  final RetroDosboxCore core;
  final Duration pollInterval;

  /// Touch on the picture itself, reported in picture-relative coordinates.
  ///
  /// These live HERE rather than in a GestureDetector wrapped around this
  /// widget because only this widget knows where the picture actually ended
  /// up. It is centred, letterboxed to one of four aspect modes, optionally
  /// bezelled and optionally rotated, and the emulated screen occupies a
  /// different rectangle in each case. A caller outside would have to
  /// reproduce all of that to turn a finger into a pixel, and would be wrong
  /// the moment any of it changed. Attached directly to the painter, the
  /// local coordinate space IS the emulated screen.
  final FramebufferTouchDown? onTouchDown;
  final FramebufferTouchMove? onTouchMove;
  final void Function(int pointers)? onTouchUp;

  const FramebufferView({
    super.key,
    required this.core,
    this.pollInterval = const Duration(milliseconds: 16), // ~60fps
    this.onTouchDown,
    this.onTouchMove,
    this.onTouchUp,
  });

  @override
  State<FramebufferView> createState() => _FramebufferViewState();
}

class _FramebufferViewState extends State<FramebufferView> {
  /// Fingers currently down on the picture, by pointer id. A set rather than
  /// a counter so a cancelled or lost pointer cannot leave the tally wrong.
  final Set<int> _pointers = <int>{};

  /// Where the finger was last seen, for turning absolute touch positions
  /// into the relative movement a PS/2 mouse actually reports.
  Offset? _lastLocal;

  ui.Image? _image;
  Timer? _timer;
  bool _decoding = false;
  int _lastW = 0, _lastH = 0;
  int _lastFrameCounter = -1;
  double _lastAspect = 4 / 3;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.pollInterval, (_) => _tick());
  }

  void _tick() {
    // Still decoding the previous frame: dropping this one is correct. Queuing
    // would only build latency, since the core has already moved on.
    if (_decoding) return;

    final counter = widget.core.frameCounter;
    if (counter == _lastFrameCounter) return;

    final frame = widget.core.getFramebuffer();
    if (frame == null) return;
    _lastFrameCounter = counter;

    _decoding = true;
    ui.decodeImageFromPixels(
      frame.bytes,
      frame.width,
      frame.height,
      // 0xAARRGGBB little-endian words == B,G,R,A in memory. Matches the
      // format documented in dosbox_bridge.h, so there is no conversion pass.
      ui.PixelFormat.bgra8888,
      (ui.Image img) {
        _decoding = false;
        if (!mounted) {
          img.dispose();
          return;
        }
        final old = _image;
        setState(() {
          _image = img;
          _lastW = frame.width;
          _lastH = frame.height;
          _lastAspect = _resolveAspect(frame.width, frame.height);
        });
        old?.dispose();
      },
    );
  }

  /// The display aspect for the current mode: what the core reports, else the
  /// raw pixel ratio. `pixelAspect` is the ratio of a single emulated pixel's
  /// width to its height, so the displayed shape is (w/h) * pixelAspect.
  double _resolveAspect(int w, int h) {
    if (w <= 0 || h <= 0) return 4 / 3;
    final pixelAspect = widget.core.pixelAspect;
    if (pixelAspect == null || pixelAspect <= 0) return w / h;
    return (w / h) * pixelAspect;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      return const Center(
        child: Text(
          'Waiting for first frame...',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    final settings = VideoSettings.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final painter = CustomPaint(
          painter: _FramebufferPainter(
            image: img,
            crt: settings.crt,
            scanlineIntensity: settings.scanlineIntensity,
            smooth: settings.smooth,
          ),
          size: Size(_lastW.toDouble(), _lastH.toDouble()),
        );

        final touchable = _touchLayer(painter);

        Widget picture;
        switch (settings.aspect) {
          case AspectMode.stretch:
            picture = SizedBox.expand(child: touchable);
          case AspectMode.square:
            picture = AspectRatio(
              aspectRatio: _lastH == 0 ? 4 / 3 : _lastW / _lastH,
              child: touchable,
            );
          case AspectMode.integer:
            picture = LayoutBuilder(builder: (context, constraints) {
              final scale = _integerScale(constraints, _lastW, _lastH);
              return Center(
                child: SizedBox(
                  width: _lastW * scale,
                  height: _lastH * scale,
                  child: touchable,
                ),
              );
            });
          case AspectMode.authentic:
            picture = AspectRatio(aspectRatio: _lastAspect, child: touchable);
        }

        if (settings.bezel) picture = _Bezel(child: picture);
        if (settings.rotationQuarterTurns != 0) {
          picture = RotatedBox(
            quarterTurns: settings.rotationQuarterTurns,
            child: picture,
          );
        }
        return picture;
      },
    );
  }

  /// Wraps the picture in a raw pointer listener when anyone is interested.
  ///
  /// Listener rather than GestureDetector, deliberately. A touchscreen
  /// pointer is not a gesture to be recognised and arbitrated: every touch is
  /// meaningful the instant it lands, and it must not be withheld while
  /// Flutter decides whether it might become a tap, a drag or a scroll. The
  /// gesture-arena version of this lost the very first movement of every
  /// touch to the drag threshold and cancelled taps that turned into drags.
  Widget _touchLayer(Widget painter) {
    if (widget.onTouchDown == null &&
        widget.onTouchMove == null &&
        widget.onTouchUp == null) {
      return painter;
    }
    // The LayoutBuilder is what makes the arithmetic below correct: its
    // constraints are the picture's own box, and PointerEvent.localPosition
    // is relative to the Listener inside it. Measuring the FramebufferView
    // instead would divide by the letterboxed outer area and put the pointer
    // in the wrong place in every aspect mode but stretch.
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            _pointers.add(e.pointer);
            _lastLocal = e.localPosition;
            widget.onTouchDown
                ?.call(_normalise(e.localPosition, size), _pointers.length);
          },
          onPointerMove: (e) {
            final previous = _lastLocal;
            _lastLocal = e.localPosition;
            if (previous == null || size.width <= 0 || size.height <= 0) {
              return;
            }
            // Picture pixels -> emulated pixels. A 640x480 guest drawn at
            // 1440 wide moves the pointer 640/1440 of a pixel per pixel of
            // finger, which is what makes the pointer track the finger at
            // whatever scale the picture happens to be drawn.
            final d = e.localPosition - previous;
            widget.onTouchMove?.call(Offset(
              d.dx * _lastW / size.width,
              d.dy * _lastH / size.height,
            ));
          },
          onPointerUp: (e) {
            _pointers.remove(e.pointer);
            if (_pointers.isEmpty) _lastLocal = null;
            widget.onTouchUp?.call(_pointers.length);
          },
          onPointerCancel: (e) {
            _pointers.remove(e.pointer);
            if (_pointers.isEmpty) _lastLocal = null;
            widget.onTouchUp?.call(_pointers.length);
          },
          child: painter,
        );
      },
    );
  }

  /// Local pixels -> fraction of the picture, clamped so a finger that slides
  /// off the edge holds the pointer against that edge instead of asking for a
  /// position outside the screen.
  static Offset _normalise(Offset local, Size size) {
    if (!size.isFinite || size.width <= 0 || size.height <= 0) {
      return Offset.zero;
    }
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  /// Whole-number scale for integer mode, never below 1: a window smaller than
  /// one DOS screen still shows the picture (clipped by the parent) rather
  /// than being blown up to a fractional size.
  static double _integerScale(BoxConstraints c, int w, int h) {
    if (w <= 0 || h <= 0) return 1;
    final byWidth = (c.maxWidth / w).floorToDouble();
    final byHeight = (c.maxHeight / h).floorToDouble();
    final scale = byWidth < byHeight ? byWidth : byHeight;
    return scale < 1 ? 1 : scale;
  }
}

/// The monitor surround drawn when the Bezel setting is on.
class _Bezel extends StatelessWidget {
  final Widget child;
  const _Bezel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF14171B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF3A424D), width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black, blurRadius: 24, spreadRadius: 2),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: child,
      ),
    );
  }
}

class _FramebufferPainter extends CustomPainter {
  final ui.Image image;
  final bool crt;
  final double scanlineIntensity;
  final bool smooth;

  _FramebufferPainter({
    required this.image,
    required this.crt,
    required this.scanlineIntensity,
    required this.smooth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()
      ..filterQuality = smooth ? FilterQuality.medium : FilterQuality.none;
    canvas.drawImageRect(image, src, dst, paint);
    if (!crt) return;

    // One dark line per emulated scanline plus a soft vignette, drawn at
    // output resolution. Skipped when the lines would be thinner than a couple
    // of device pixels -- below that they stop reading as scanlines and just
    // turn the whole picture grey.
    final rowHeight = size.height / image.height;
    if (rowHeight >= 2.0) {
      final linePaint = Paint()
        ..color = Colors.black.withValues(alpha: scanlineIntensity)
        ..strokeWidth = rowHeight / 2;
      for (double y = rowHeight / 2; y < size.height; y += rowHeight) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
      }
    }
    final vignette = Paint()
      ..shader = RadialGradient(
        radius: 0.85,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: 0.28 * scanlineIntensity + 0.12),
        ],
        stops: const [0.65, 1.0],
      ).createShader(dst);
    canvas.drawRect(dst, vignette);
  }

  @override
  bool shouldRepaint(covariant _FramebufferPainter old) =>
      old.image != image ||
      old.crt != crt ||
      old.smooth != smooth ||
      old.scanlineIntensity != scanlineIntensity;
}
