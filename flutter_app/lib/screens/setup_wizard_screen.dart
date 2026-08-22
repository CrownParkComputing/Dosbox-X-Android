// First-run setup, styled as a DOS boot sequence.
//
// The VICE app's wizard imitates a C64 BASIC screen; this one imitates a PC
// booting to a DOS prompt, for the same reason: the first thing a user sees
// should tell them what they are about to run. The typing animation is not
// decoration either -- it paces the wizard so each line is read before the
// folder picker takes over the screen.
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_prefs.dart';
import '../services/demo_program_service.dart';
import '../theme/retrodosbox_theme.dart';

class SetupWizardScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const SetupWizardScreen({super.key, required this.onComplete});

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
    'A clean install starts in COMPLIANCE MODE.',
    '',
    'Only a bundled FreeDOS 1.4 environment is visible.',
    'It runs an original, MIT-licensed homebrew demo.',
    'No external BIOS, account, download or user file is needed.',
    '',
    'No Microsoft DOS, Windows, commercial game, ROM or BIOS',
    'dump is included. Use only software you have the right to use.',
    '',
    'Compliance mode can be changed anytime from the sidebar.',
    'While active, your own library is not scanned or displayed.',
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

  Future<void> _finish() async {
    await AppPrefs.setComplianceMode(true);
    await AppPrefs.setSetupCompleted(true);
    if (!mounted) return;
    widget.onComplete();
  }

  Future<void> _runDemo() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final demo = await DemoProgramService.prepare();
      await AppPrefs.setPendingLaunch(demo.entry.slug);
      await _finish();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            if (_awaitingChoice) _actions(),
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
            onPressed: _busy ? null : _runDemo,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Boot FreeDOS homebrew demo'),
          ),
          TextButton(
            onPressed: _busy ? null : _finish,
            child: const Text(
              'Continue in compliance mode',
              style: TextStyle(color: RetroDosboxColors.textMuted2),
            ),
          ),
        ],
      ),
    );
  }
}
