// Offline, reviewer-facing proof of the app's content and isolation model.
//
// This page is deliberately available at all times. First-run prose can be
// skipped and store notes can be missed; the running app itself remains the
// authoritative explanation of what ships, how the demo works, and why no
// proprietary BIOS or commercial software belongs in the bundle.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';

import '../services/demo_program_service.dart';
import '../theme/retrodosbox_theme.dart';

class ComplianceScreen extends StatefulWidget {
  final bool complianceMode;
  final Future<void> Function(bool enabled) onModeChanged;
  final Future<void> Function() onRunDemo;

  const ComplianceScreen({
    super.key,
    required this.complianceMode,
    required this.onModeChanged,
    required this.onRunDemo,
  });

  @override
  State<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends State<ComplianceScreen> {
  DemoProgramInstallation? _installation;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEvidence();
  }

  Future<void> _loadEvidence() async {
    try {
      final installation = await DemoProgramService.prepare();
      if (!mounted) return;
      setState(() => _installation = installation);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _setMode(bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onModeChanged(enabled);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runDemo() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRunDemo();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens one of the bundled compliance files as plain text.
  Future<void> _showBundledFile(
      BuildContext context, DemoProgramInstallation inst, String name) async {
    String text;
    try {
      text = await File(p.join(inst.directory.path, name)).readAsString();
    } catch (e) {
      text = '(could not read $name: $e)';
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(name, style: const TextStyle(fontSize: 14)),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final installation = _installation;
    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 24),
      children: [
        const Text(
          'Store Compliance & Legal Use',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Offline evidence for users and app review. No account or network '
          'connection is needed.',
          style: RetroDosboxTextStyles.statusLine,
        ),
        const SizedBox(height: 14),
        _modeCard(),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            'Could not prepare the review environment: $_error',
            style: const TextStyle(color: RetroDosboxColors.warning),
          ),
        ],
        const _Section(
          title: '1. A complete legal demo is included',
          body:
              'The bundled FREEDOS.IMG boots FreeDOS 1.4 and automatically '
              'runs RETRODEM.COM, an original homebrew program created for '
              'this app. This is real guest software running inside DOSBox-X, '
              'not a mock screen. It needs no account, download, external '
              'BIOS, game, or user file.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy || installation == null ? null : _runDemo,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Boot FreeDOS homebrew demo'),
          ),
        ),
        const _Section(
          title: '2. Compliance mode is an isolated library',
          body:
              'While the mode is active, the app does not resolve, scan, '
              'list, display, or launch the user\'s games folder. Paths is '
              'hidden, user-editable settings pages are hidden, and Games '
              'contains only the bundled FreeDOS demo. '
              'Turning the mode on ends any current user session first. '
              'Turning it off restores the normal library without moving or '
              'changing any user file.',
        ),
        const _Section(
          title: '3. What the app ships',
          body:
              'Included: the DOSBox-X emulator, the FreeDOS kernel and '
              'FreeCOM shell under GNU GPL v2, and the original MIT-licensed '
              'homebrew demo with its complete source.\n\n'
              'Not included: Microsoft DOS, Microsoft Windows, commercial '
              'games, game downloads, ROM sets, proprietary PC BIOS dumps, '
              'activation keys, disc images, or links to infringing content.',
        ),
        const _Section(
          title: '4. No proprietary BIOS is required',
          body:
              'DOSBox-X emulates the PC firmware services needed by this '
              'app. Users do not need to find or download a PC BIOS. A BIOS '
              'or operating-system image taken from commercial hardware or '
              'software must never be distributed with this app unless the '
              'rights holder has granted redistribution permission.',
        ),
        const _Section(
          title: '5. Software users may add',
          body:
              'Use software you created, public-domain or open-source '
              'software, homebrew, or software whose licence gives you the '
              'right to use your copy. You may also use a personal archival '
              'copy only where the software licence and the law where you '
              'live permit it.\n\n'
              'Owning an original does not automatically make a download from '
              'an unrelated ROM or abandonware site lawful. The app provides '
              'no search, catalogue, downloader, or links for commercial '
              'software.',
        ),
        const _Section(
          title: '6. FreeDOS and homebrew provenance',
          body:
              'The minimal image is reproducibly derived from the official '
              'FreeDOS 1.4 Floppy Edition. Only KERNEL.SYS, COMMAND.COM, the '
              'startup files, the demo and licence documents remain. The '
              'official archive hash, exact component list, source links, '
              'image recipe and licence texts all ship beside the image.',
        ),
        if (installation != null) ...[
          const SizedBox(height: 8),
          const Text(
            'Installed in the app\'s private compliance-demo directory:',
            style: TextStyle(
              color: RetroDosboxColors.textMuted2,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 6),
          // Tappable, not just listed: the claim "recipes and hashes are
          // included in the app" is only checkable by a reviewer if the
          // app can OPEN them -- the private directory is unreachable
          // from a file manager on iOS/Android.
          for (final file in installation.files)
            InkWell(
              onTap: () => _showBundledFile(context, installation, file),
              child: Text(
                '  • $file',
                style: const TextStyle(
                  color: RetroDosboxColors.accentAmber,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
        ],
        const _Section(
          title: '7. Privacy',
          body:
              'No account, analytics, advertising, tracking, or developer '
              'network service is used. Game files and settings stay on the '
              'device. File access is initiated by the user and is used only '
              'to import or run the software they selected.',
        ),
        const _Section(
          title: '8. Source and licences',
          body:
              'DOSBox-X: GNU GPL v2\n'
              'github.com/joncampbell123/dosbox-x\n\n'
              'FreeDOS kernel: GNU GPL v2 or later\n'
              'github.com/FDOS/kernel\n\n'
              'FreeCOM: GNU GPL v2\n'
              'github.com/FDOS/freecom\n\n'
              'App and demo source:\n'
              'github.com/CrownParkComputing/DosboxMultiplatform',
        ),
      ],
    );
  }

  Widget _modeCard() {
    final active = widget.complianceMode;
    return Container(
      decoration: BoxDecoration(
        color: active
            ? RetroDosboxColors.accentAmber.withValues(alpha: 0.10)
            : RetroDosboxColors.cardFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active
              ? RetroDosboxColors.accentAmber
              : RetroDosboxColors.cardStroke,
        ),
      ),
      child: SwitchListTile(
        value: active,
        onChanged: _busy ? null : _setMode,
        activeThumbColor: RetroDosboxColors.accentAmber,
        title: Text(
          active ? 'COMPLIANCE MODE ACTIVE' : 'Compliance mode is off',
          style: TextStyle(
            color: active ? RetroDosboxColors.accentAmber : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          active
              ? 'Only the bundled FreeDOS demo is visible. User content is not scanned.'
              : 'Your own library is available. Turn this on before store review.',
          style: const TextStyle(color: RetroDosboxColors.textMuted2),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;

  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: RetroDosboxColors.accentAmber,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(
              color: RetroDosboxColors.textMuted2,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
