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
class FramebufferView extends StatefulWidget {
  final RetroDosboxCore core;
  final Duration pollInterval;

  const FramebufferView({
    super.key,
    required this.core,
    this.pollInterval = const Duration(milliseconds: 16), // ~60fps
  });

  @override
  State<FramebufferView> createState() => _FramebufferViewState();
}

class _FramebufferViewState extends State<FramebufferView> {
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

        Widget picture;
        switch (settings.aspect) {
          case AspectMode.stretch:
            picture = SizedBox.expand(child: painter);
          case AspectMode.square:
            picture = AspectRatio(
              aspectRatio: _lastH == 0 ? 4 / 3 : _lastW / _lastH,
              child: painter,
            );
          case AspectMode.integer:
            picture = LayoutBuilder(builder: (context, constraints) {
              final scale = _integerScale(constraints, _lastW, _lastH);
              return Center(
                child: SizedBox(
                  width: _lastW * scale,
                  height: _lastH * scale,
                  child: painter,
                ),
              );
            });
          case AspectMode.authentic:
            picture = AspectRatio(aspectRatio: _lastAspect, child: painter);
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
