// About / credits tab.
//
// The point of this screen is proportion: DOSBox-X does the emulation, and
// this app draws its output and collects input for it. Anyone reading this
// tab should come away knowing which project to thank, which project to file
// an emulation bug against, and that the licence of the core is GPLv2.
//
// Nothing here is invented. Only the one repository named below is cited --
// no version numbers, no author lists, no sponsor credits -- because anything
// else would have to be maintained in step with an upstream this app does not
// control.
import 'package:flutter/material.dart';

import '../services/platform_info.dart';
import '../theme/retrodosbox_theme.dart';

class AboutScreen extends StatelessWidget {
  final VoidCallback? onOpenCompliance;

  const AboutScreen({super.key, this.onOpenCompliance});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('About',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('DOSBox Multiplatform',
            style: TextStyle(color: RetroDosboxColors.textMuted2)),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            onPressed: onOpenCompliance,
            icon: const Icon(Icons.verified_outlined, size: 18),
            label: const Text('Store Compliance & Legal Use'),
          ),
        ),
        _Card(
          title: 'What this is',
          body: 'A front end. This app browses your DOS games, writes the '
              'configuration for a session, shows the emulator\'s picture and '
              'feeds it keyboard, mouse and joystick input. It does not '
              'emulate anything itself -- there is no CPU, no VGA and no '
              'sound chip in this codebase.\n\n'
              'Running on: ${platformName()}',
        ),
        const _Card(
          title: 'DOSBox-X',
          body: 'All of the actual work is DOSBox-X: the x86 CPU, the video '
              'and sound hardware, the DOS itself, the disk and CD-ROM '
              'emulation and the compatibility with thousands of titles. If a '
              'game runs correctly here, that is DOSBox-X. Enormous thanks to '
              'the DOSBox-X project for a core that is both accurate and '
              'genuinely portable.\n\n'
              'Licensed under the GNU General Public License, version 2.\n\n'
              'https://github.com/joncampbell123/dosbox-x',
          accent: true,
        ),
        const _Card(
          title: 'FreeDOS review environment',
          body: 'Compliance mode boots a minimal FreeDOS 1.4 image containing '
              'only the GPL-licensed FreeDOS kernel and FreeCOM shell, plus '
              'this app\'s original MIT-licensed homebrew demo. The exact '
              'source links, licences, official archive hash and reproducible '
              'image recipe are included in the app. No Microsoft DOS, '
              'Windows, commercial game or proprietary BIOS is included.',
        ),
        const _Card(
          title: 'DOSBox',
          body: 'DOSBox-X is a fork of DOSBox, and much of what makes DOS '
              'games run at all on modern machines was built there first. The '
              'debt to the original DOSBox project runs through every part of '
              'the core this app embeds.',
        ),
        const _Card(
          title: 'Game Link output',
          body: 'The offscreen rendering this app depends on is not a custom '
              'patch bolted onto the emulator. It reuses DOSBox-X\'s own Game '
              'Link output backend, which already publishes each finished '
              'frame to an external consumer. Building on an existing, '
              'supported output path is what keeps this front end from '
              'diverging from upstream.',
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final String title;
  final String body;
  final bool accent;

  const _Card({required this.title, required this.body, this.accent = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: RetroDosboxColors.cardFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: accent ? RetroDosboxColors.accentAmber : RetroDosboxColors.cardStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: accent ? RetroDosboxColors.accentAmber : Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(
                  color: RetroDosboxColors.textMuted2, height: 1.4)),
        ],
      ),
    );
  }
}
