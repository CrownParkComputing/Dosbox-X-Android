// First-run setup, styled as a DOS boot sequence.
//
// The VICE app's wizard imitates a C64 BASIC screen; this one imitates a PC
// booting to a DOS prompt, for the same reason: the first thing a user sees
// should tell them what they are about to run. Like Retro-C64, it asks one
// question before touching the user's library: isolated Store Compliance, or
// Regular Mode for the user's own lawfully obtained software.
import 'dart:async';

import '../services/permissions_service.dart';
import 'getting_started.dart';
import 'package:flutter/material.dart';

import '../services/app_prefs.dart';
import '../services/demo_program_service.dart';
import '../theme/retrodosbox_theme.dart';

Future<String> _prepareComplianceDemo() async {
  final demo = await DemoProgramService.prepare();
  return demo.entry.slug;
}

/// The family's phased shape, from Retro-Amiga.
enum _Phase { welcome, primer, console }

class SetupWizardScreen extends StatefulWidget {
  final VoidCallback onComplete;
  final Future<String> Function() prepareComplianceDemo;
  final String? appBuild;

  const SetupWizardScreen({
    super.key,
    required this.onComplete,
    this.appBuild,
    this.prepareComplianceDemo = _prepareComplianceDemo,
  });

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  /// Lines already fully typed.
  final List<String> _done = <String>[];

  /// The line currently being typed, partially revealed.
  String _current = '';
  int _charIndex = 0;
  Timer? _typeTimer;

  List<String> _pending = <String>[];
  bool _awaitingChoice = false;
  bool _busy = false;

  /// The family's phased shape, from Retro-Amiga: introduce, teach, then the
  /// DOS boot screen asks the one question.
  _Phase _phase = _Phase.welcome;

  @override
  void initState() {
    super.initState();
    _queue(_introLines);
  }

  static const List<String> _introLines = [
    'DOSBox-X Multiplatform',
    '',
    'Memory Test: 640K OK',
    '',
    'This app runs PC software using the DOSBox-X emulator.',
    'Choose how you want to begin.',
    '',
    'STORE COMPLIANCE MODE',
    'Runs only the bundled FreeDOS 1.4 homebrew demo.',
    'Your library is not scanned, displayed or launched.',
    'No BIOS, account, download or user file is needed.',
    '',
    'REGULAR MODE',
    'Lets you add DOS software you have the right to use.',
    'No Microsoft DOS, Windows, commercial game, ROM or BIOS',
    'dump is supplied by this app.',
    '',
    'You can change modes anytime from Compliance.',
    '',
  ];

  void _queue(List<String> lines) {
    _pending = [...lines];
    _typeNext();
  }

  void _typeNext() {
    _typeTimer?.cancel();
    if (_pending.isEmpty) {
      setState(() => _awaitingChoice = true);
      return;
    }
    final line = _pending.removeAt(0);
    _current = line;
    _charIndex = 0;
    if (line.isEmpty) {
      // Blank lines are pacing, not content -- commit immediately and pause
      // briefly rather than "typing" nothing for a frame.
      setState(() => _done.add(''));
      _typeTimer = Timer(const Duration(milliseconds: 90), _typeNext);
      return;
    }
    _typeTimer = Timer.periodic(const Duration(milliseconds: 12), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _charIndex++);
      if (_charIndex >= _current.length) {
        t.cancel();
        setState(() {
          _done.add(_current);
          _current = '';
          _charIndex = 0;
        });
        _typeTimer = Timer(const Duration(milliseconds: 40), _typeNext);
      }
    });
  }

  @override
  void dispose() {
    _typeTimer?.cancel();
    super.dispose();
  }

  Future<void> _finish({required bool complianceMode}) async {
    await AppPrefs.setComplianceMode(complianceMode);
    final appBuild = widget.appBuild;
    if (appBuild == null) {
      await AppPrefs.setSetupCompleted(true);
    } else {
      await AppPrefs.setSetupCompletedForBuild(appBuild);
    }
    if (!mounted) return;
    widget.onComplete();
  }

  Future<void> _storeCompliance() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final demoSlug = await widget.prepareComplianceDemo();
      await AppPrefs.setPendingLaunch(demoSlug);
      await _finish(complianceMode: true);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not prepare the FreeDOS demo: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _regularMode() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Regular mode means reading the user's own games in place, so ask
      // for the access first. Declining is allowed: the SAF folder grant
      // remains as the no-permission fallback.
      await PermissionsService.ensure();
      await _finish(complianceMode: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: SafeArea(
        child: switch (_phase) {
          _Phase.welcome => _welcomeView(),
          _Phase.primer => _primerView(),
          _Phase.console => _consoleView(),
        },
      ),
    );
  }

  Widget _welcomeView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset(
                  'assets/images/app_icon.png',
                  height: 104,
                  width: 104,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (c, e, st) =>
                      const Icon(Icons.computer, size: 72),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Retro-DOSBox',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'A DOS PC, running on this device. FreeDOS is built in, so it '
              'boots right now — and your own games are read where they '
              'already are.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, height: 1.5),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => setState(() => _phase = _Phase.primer),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Get started'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _phase = _Phase.console),
              child: const Text('I have done this before'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _primerView() {
    return GettingStartedGuide(
      steps: [
        GettingStartedSteps.whatYouNeed(),
        GettingStartedSteps.whereFilesGo(),
      ],
      closeLabel: 'C:\\> BOOT',
      onClose: () => setState(() => _phase = _Phase.console),
      onBack: () => setState(() => _phase = _Phase.welcome),
    );
  }

  Widget _consoleView() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(20),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                reverse: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in _done)
                      Text(line, style: RetroDosboxTextStyles.terminal),
                    if (_current.isNotEmpty)
                      Text(
                        _current.substring(0, _charIndex),
                        style: RetroDosboxTextStyles.terminal,
                      ),
                    if (_awaitingChoice) ...[
                      const SizedBox(height: 8),
                      Text(
                        'A:\\> RETRODEM _',
                        style: RetroDosboxTextStyles.terminal,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _actions(),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      // Wrap, not Row: the wizard body is laid out to the width of the DOS text
      // column, and the two buttons together exceed it on an iPad in portrait
      // (measured: overflow by 32px, clipping "Skip for now"). Wrapping lets
      // the second button drop to its own line instead of being cut off.
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _storeCompliance,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.verified_outlined),
            label: const Text('Store Compliance'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _regularMode,
            icon: const Icon(Icons.folder_open),
            label: const Text('Regular Mode'),
          ),
        ],
      ),
    );
  }
}
