// Video Settings tab.
//
// Every control here writes to VideoSettings.instance, which is the object
// FramebufferView actually reads when it paints. Nothing on this screen keeps
// a local copy of a setting: a local bool would let the switch and the picture
// disagree, and the in-game Quick Settings panel edits the same singleton, so
// both surfaces have to observe it rather than own it.
import 'package:flutter/material.dart';

import '../services/video_settings.dart';
import '../theme/dosbox_theme.dart';

class VideoSettingsScreen extends StatelessWidget {
  const VideoSettingsScreen({super.key});

  Widget _card({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DosColors.cardFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: DosColors.cardStroke),
        ),
        child: child,
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: const TextStyle(
                      color: DosColors.textMuted2, fontSize: 12)),
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: DosColors.accentAmber,
          onChanged: onChanged,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = VideoSettings.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        // The scanline slider stays MOUNTED but disabled when the CRT effect
        // is off, rather than being removed from the tree. Hiding it makes
        // the card jump in height every time the switch is flipped, and the
        // greyed-out slider also communicates that the value is remembered
        // and will come back with the effect.
        final crtOn = settings.crt;
        final scanlineColour =
            crtOn ? DosColors.accentAmber : DosColors.textMuted;

        return ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Video Settings',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Screen size',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 4),
                  const Text(
                    'How the DOS picture is fitted to the screen. Authentic '
                    'uses the display aspect DOSBox-X reports for the current '
                    'video mode, which is not the same as the pixel '
                    'dimensions: 320x200 was a 4:3 picture on real hardware. '
                    'Integer scale keeps every emulated pixel the same size, '
                    'so scrolling never shimmers.',
                    style:
                        TextStyle(color: DosColors.textMuted2, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in AspectMode.values)
                        ChoiceChip(
                          label: Text(mode.label),
                          selected: settings.aspect == mode,
                          onSelected: (_) => settings.setAspect(mode),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _switchRow(
                    title: 'CRT effect',
                    subtitle:
                        'Scanlines and a soft vignette over the picture.',
                    value: crtOn,
                    onChanged: settings.setCrt,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('Scanline strength',
                          style:
                              TextStyle(color: scanlineColour, fontSize: 12)),
                      Expanded(
                        child: Slider(
                          value: settings.scanlineIntensity,
                          activeColor: DosColors.accentAmber,
                          // A null callback is what disables (and greys) a
                          // Slider in Material; there is no `enabled` flag.
                          onChanged:
                              crtOn ? settings.setScanlineIntensity : null,
                        ),
                      ),
                      Text(
                        '${(settings.scanlineIntensity * 100).round()}%',
                        style: TextStyle(color: scanlineColour, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _card(
              child: _switchRow(
                title: 'Bezel',
                subtitle:
                    'Draws a monitor surround around the picture instead of '
                    'running it to the screen edge.',
                value: settings.bezel,
                onChanged: settings.setBezel,
              ),
            ),
            _card(
              child: _switchRow(
                title: 'Smooth scaling',
                subtitle:
                    'Filters the picture when it is scaled. Off gives hard, '
                    'authentic pixel edges.',
                value: settings.smooth,
                onChanged: settings.setSmooth,
              ),
            ),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Rotation',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 4),
                  const Text(
                    'For vertically-oriented games on a handheld held '
                    'sideways.',
                    style:
                        TextStyle(color: DosColors.textMuted2, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('0°')),
                      ButtonSegment(value: 1, label: Text('90°')),
                      ButtonSegment(value: 2, label: Text('180°')),
                      ButtonSegment(value: 3, label: Text('270°')),
                    ],
                    selected: {settings.rotationQuarterTurns},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        settings.setRotationQuarterTurns(s.first),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
