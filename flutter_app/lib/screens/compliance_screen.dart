// The App Store / Play Store compliance page.
//
// One place that answers, on the device and with no network connection, every
// question a store review team asks about an emulator: what does it ship, what
// does it not ship, under what licences, what can it do with nothing supplied
// by the user, and where are the files that prove it.
//
// The sibling of Retro-C64's and Retro-Amiga's compliance screens,
// deliberately: the three apps are reviewed by the same people against the
// same rules, and an answer phrased differently in each is an answer that has
// to be checked twice.
//
// What differs here is the answer itself. The other two ship a free ROM
// because their machines cannot boot without one. A PC can: DOSBox-X provides
// its own DOS, so this app needs no system software at all to run -- and it
// ships FreeDOS anyway, for the software that wants a real DOS underneath it.
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/compliance_mode.dart';
import '../services/demo_program.dart';
import '../services/dos_mode.dart';

class ComplianceScreen extends StatefulWidget {
  const ComplianceScreen({super.key});

  @override
  State<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends State<ComplianceScreen> {
  DosMode _mode = DosMode.builtIn;
  bool _compliance = false;
  bool _busy = true;
  String _imagePath = '';
  String _demoPath = '';
  bool _demoPresent = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mode = await DosModeService.current();
    final compliance = await ComplianceMode.isOn();
    final image = await DosModeService.imagePath();
    final demo = await DemoProgram.installedPath();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _compliance = compliance;
      _imagePath = image;
      _demoPath = demo;
      _demoPresent = File(demo).existsSync();
      _busy = false;
    });
  }

  Future<void> _setMode(DosMode mode) async {
    setState(() => _busy = true);
    await DosModeService.set(mode);
    // Extracted here rather than at boot so that choosing the mode is what
    // reports a failure, instead of a launch that quietly falls back.
    if (mode == DosMode.freeDos) await DosModeService.ensureImage();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _busy = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mode == DosMode.freeDos
            ? 'FreeDOS will boot the next time a session starts.'
            : "DOSBox-X's built-in DOS is back."),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        const Text('App Store / Play Store compliance',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),

        _Section('What this app ships', const <String>[
          'DOSBox-X, the emulator itself, under the GNU GPL v2.',
          'FreeDOS 1.3, a complete free DOS, as a boot floppy image. '
              'Redistributed unmodified; its kernel is GPL v2 and its '
              'utilities carry their own free licences.',
          'DEMO.COM, a small demo program written for this app.',
        ]),

        _Section('What it does NOT ship', const <String>[
          'No MS-DOS. It is Microsoft\'s, and it is not here in any form.',
          'No games, no shareware, no abandonware.',
          'Nothing is downloaded at runtime. The app makes no network '
              'requests at all.',
        ]),

        _Section('What runs with nothing supplied by the user', <String>[
          'A working PC, immediately. Unlike a C64 or an Amiga, a PC needs no '
              'ROM: DOSBox-X provides the DOS services itself.',
          _demoPresent
              ? 'DEMO.COM is on the shelf now, at $_demoPath'
              : 'DEMO.COM installs onto the shelf at first launch.',
        ]),

        const SizedBox(height: 8),
        const Text('Compliance mode',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        SwitchListTile(
          value: _compliance,
          onChanged: (on) async {
            setState(() => _busy = true);
            await ComplianceMode.set(on);
            if (!mounted) return;
            setState(() {
              _compliance = on;
              _busy = false;
            });
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(on
                  ? 'Compliance mode on. The shelf now lists only the bundled '
                      'demo.'
                  : 'Compliance mode off. Your own games folder is back.'),
            ));
          },
          title: const Text('Show only what the app shipped with'),
          subtitle: const Text(
            'The library reads a directory holding nothing but the bundled '
            'demo, so the app can only run what came with it. Your own files '
            'are untouched and return the moment this is switched off.',
          ),
        ),

        const SizedBox(height: 8),
        const Text('Which DOS runs',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Both choices are free software and both are bundled. Neither is '
          'MS-DOS.',
          style: TextStyle(height: 1.4),
        ),
        const SizedBox(height: 8),

        _ModeTile(
          selected: _mode == DosMode.builtIn,
          title: "DOSBox-X's built-in DOS",
          body: 'The default. Not a boot at all -- the emulator provides DOS '
              'itself and mounts your games folder as C:. Starts fastest, and '
              'is what almost every DOS program wants.',
          onTap: () => _setMode(DosMode.builtIn),
        ),
        _ModeTile(
          selected: _mode == DosMode.freeDos,
          title: 'FreeDOS 1.3',
          body: 'Boots the bundled FreeDOS floppy, so a genuine DOS kernel is '
              'underneath. Slower to start, and your games folder arrives as a '
              'second drive rather than C:. Use it for software that insists '
              'on a real DOS.\n\nImage: $_imagePath',
          onTap: () => _setMode(DosMode.freeDos),
        ),

        const SizedBox(height: 16),
        _Section('Why FreeDOS at all, if the built-in DOS works', const <String>[
          'Because "works" is not the same as "is a DOS". DOSBox-X '
              'reimplements the DOS calls a program makes; FreeDOS is an '
              'actual DOS that boots. Most software cannot tell the '
              'difference, and a little of it can.',
          'Because it is the honest answer to "what runs if I own no DOS?" -- '
              'a free replacement for MS-DOS, shipped so nobody has to find '
              'a copy of somebody else\'s operating system.',
          'Its full source and per-package licences are at freedos.org; the '
              'image here is redistributed unmodified. See '
              'assets/freedos/README.txt in the app bundle.',
        ]),
      ],
    );
  }
}

/// One selectable mode. A ListTile rather than a RadioListTile: the Radio
/// widgets' groupValue/onChanged are deprecated in favour of a RadioGroup
/// ancestor, and two mutually exclusive rows do not need one.
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.selected,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: selected ? null : onTap,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(title,
            style: TextStyle(
                fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
        subtitle: Text(body, style: const TextStyle(height: 1.4)),
        isThreeLine: true,
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.points);

  final String title;
  final List<String> points;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          for (final point in points)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('•  '),
                  Expanded(child: Text(point, style: const TextStyle(height: 1.4))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
