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
import 'logs_screen.dart';
import 'getting_started.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/app_prefs.dart';
import '../services/platform_info.dart';
import '../theme/retrodosbox_theme.dart';
import 'why_not_windows_screen.dart';

class AboutScreen extends StatelessWidget {
  final VoidCallback? onOpenCompliance;

  const AboutScreen({super.key, this.onOpenCompliance});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'About',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'DOSBox Multiplatform',
          style: TextStyle(color: RetroDosboxColors.textMuted2),
        ),
        const SizedBox(height: 4),
        const _BuildTrackingView(),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            onPressed: onOpenCompliance,
            icon: const Icon(Icons.verified_outlined, size: 18),
            label: const Text('Store Compliance & Legal Use'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            onPressed: () => WhyNotWindowsScreen.show(context),
            icon: const Icon(Icons.help_outline, size: 18),
            label: const Text('Why not Windows 95/98?'),
          ),
        ),
        // The guide setup shows, re-readable any time -- the questions it
        // answers ("where do I put my files?") are asked most often by
        // someone who finished setup long ago.
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => Scaffold(
                  backgroundColor: Colors.black,
                  body: SafeArea(
                    child: GettingStartedGuide(
                      steps: [
                        GettingStartedSteps.whatYouNeed(),
                        GettingStartedSteps.whereFilesGo(),
                        GettingStartedSteps.firstGame(),
                      ],
                      onClose: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),
            ),
            icon: const Icon(Icons.school_outlined, size: 18),
            label: const Text('Getting started guide'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LogsScreen()),
            ),
            icon: const Icon(Icons.terminal, size: 18),
            label: const Text('App log'),
          ),
        ),
        _Card(
          title: 'What this is',
          body:
              'A front end. This app browses your DOS games, writes the '
              'configuration for a session, shows the emulator\'s picture and '
              'feeds it keyboard, mouse and joystick input. It does not '
              'emulate anything itself -- there is no CPU, no VGA and no '
              'sound chip in this codebase.\n\n'
              'Running on: ${platformName()}',
        ),
        const _Card(
          title: 'DOSBox-X',
          body:
              'All of the actual work is DOSBox-X: the x86 CPU, the video '
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
          body:
              'Compliance mode boots a minimal FreeDOS 1.4 image containing '
              'only the GPL-licensed FreeDOS kernel and FreeCOM shell, plus '
              'this app\'s original MIT-licensed homebrew demo. The exact '
              'source links, licences, official archive hash and reproducible '
              'image recipe are included in the app. No Microsoft DOS, '
              'Windows, commercial game or proprietary BIOS is included.',
        ),
        const _Card(
          title: 'DOSBox',
          body:
              'DOSBox-X is a fork of DOSBox, and much of what makes DOS '
              'games run at all on modern machines was built there first. The '
              'debt to the original DOSBox project runs through every part of '
              'the core this app embeds.',
        ),
        const _Card(
          title: 'Game Link output',
          body:
              'The offscreen rendering this app depends on is not a custom '
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

const TextStyle _buildStyle = TextStyle(
  color: RetroDosboxColors.textMuted,
  fontSize: 12,
  fontFamily: 'monospace',
);

class _BuildTracking {
  final String? currentBuild;
  final String? setupBuild;

  const _BuildTracking({required this.currentBuild, required this.setupBuild});
}

class _BuildTrackingView extends StatefulWidget {
  const _BuildTrackingView();

  @override
  State<_BuildTrackingView> createState() => _BuildTrackingViewState();
}

class _BuildTrackingViewState extends State<_BuildTrackingView> {
  late final Future<_BuildTracking> _tracking = _loadBuildTracking();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BuildTracking>(
      future: _tracking,
      builder: (context, snapshot) {
        final tracking = snapshot.data;
        if (tracking == null) {
          return const Text('Build information loading…', style: _buildStyle);
        }
        return Text(
          tracking.currentBuild == null
              ? 'Current build: unavailable\n'
                    'Wizard completed for: '
                    '${tracking.setupBuild ?? 'not recorded'}'
              : 'Current build: ${tracking.currentBuild}\n'
                    'Wizard completed for: '
                    '${tracking.setupBuild ?? 'not recorded'}',
          style: _buildStyle,
        );
      },
    );
  }
}

Future<_BuildTracking> _loadBuildTracking() async {
  String? currentBuild;
  try {
    final info = await PackageInfo.fromPlatform();
    currentBuild = '${info.version}+${info.buildNumber}';
  } on Object {
    // About remains usable on a platform/test binding without the plugin.
  }
  return _BuildTracking(
    currentBuild: currentBuild,
    setupBuild: await AppPrefs.getSetupCompletedBuild(),
  );
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
          color: accent
              ? RetroDosboxColors.accentAmber
              : RetroDosboxColors.cardStroke,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: accent ? RetroDosboxColors.accentAmber : Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(
              color: RetroDosboxColors.textMuted2,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
