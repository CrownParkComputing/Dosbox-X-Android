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
import '../services/storage_access.dart';
import '../theme/dosbox_theme.dart';

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
  bool _awaitingFolder = false;
  String? _gamesFolder;

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
    'This app runs DOS games using the DOSBox-X emulator.',
    'It needs to know where your games are kept.',
    '',
    'A game is normally a folder containing its EXE files.',
    'CD images (.iso, .cue) and disk images also work.',
    '',
  ];

  void _queue(List<String> lines) {
    _pending = [...lines];
    _typeNext();
  }

  void _typeNext() {
    _typeTimer?.cancel();
    if (_pending.isEmpty) {
      setState(() => _awaitingFolder = true);
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

  Future<void> _chooseFolder() async {
    final result =
        await StorageAccess.instance.pickFolder(dialogTitle: 'Games folder');
    if (result == null || !mounted) return;
    setState(() => _gamesFolder = result.path);
  }

  Future<void> _finish() async {
    final folder = _gamesFolder;
    if (folder != null) await AppPrefs.setGamesFolderPath(folder);
    await AppPrefs.setSetupCompleted(true);
    if (!mounted) return;
    widget.onComplete();
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
                      Text(line, style: DosTextStyles.terminal),
                    if (_current.isNotEmpty)
                      Text(
                        _current.substring(0, _charIndex),
                        style: DosTextStyles.terminal,
                      ),
                    if (_awaitingFolder) ...[
                      const SizedBox(height: 8),
                      Text(
                        _gamesFolder == null
                            ? 'C:\\> _'
                            : 'C:\\> SET GAMES=$_gamesFolder',
                        style: DosTextStyles.terminal,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_awaitingFolder) _actions(),
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
          OutlinedButton(
            onPressed: _chooseFolder,
            style: OutlinedButton.styleFrom(
              foregroundColor: DosColors.accentAmber,
              side: const BorderSide(color: DosColors.accentAmber),
            ),
            child: Text(
                _gamesFolder == null ? 'Choose games folder' : 'Change folder'),
          ),
          // Skipping is allowed on purpose: a user with no games yet should be
          // able to reach the app and set the folder later from Paths, rather
          // than being trapped in the wizard.
          TextButton(
            onPressed: _finish,
            child: Text(
              _gamesFolder == null ? 'Skip for now' : 'Continue',
              style: const TextStyle(color: DosColors.textMuted2),
            ),
          ),
        ],
      ),
    );
  }
}
