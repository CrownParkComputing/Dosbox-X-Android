// Where the games live, and (on Android) whether we are allowed to read them.
import 'package:flutter/material.dart';

import '../services/app_prefs.dart';
import '../services/games_folder.dart';
import '../services/permissions_service.dart';
import '../services/storage_access.dart';
import '../theme/retrodosbox_theme.dart';

class PathsSettingsScreen extends StatefulWidget {
  /// Called after the games folder changes, so the shell can rescan.
  final VoidCallback onGamesFolderChanged;

  final VoidCallback onRunSetupWizard;

  const PathsSettingsScreen({
    super.key,
    required this.onGamesFolderChanged,
    required this.onRunSetupWizard,
  });

  @override
  State<PathsSettingsScreen> createState() => _PathsSettingsScreenState();
}

class _PathsSettingsScreenState extends State<PathsSettingsScreen> {
  String? _gamesFolder;
  bool? _hasStorageAccess;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // The resolved folder, not the raw preference: with no preference set the
    // app still HAS a games folder (the default Retro-DosBox one, created on
    // first scan), and showing "Not set" while games sit in it would be a lie.
    final games = await GamesFolder.resolve();
    final access = PermissionsService.isRelevant
        ? await PermissionsService.hasStorageAccess()
        : null;
    if (!mounted) return;
    setState(() {
      _gamesFolder = games;
      _hasStorageAccess = access;
      _loading = false;
    });
  }

  Future<void> _pickGamesFolder() async {
    final result =
        await StorageAccess.instance.pickFolder(dialogTitle: 'Games folder');
    if (result == null || !mounted) return;
    await AppPrefs.setGamesFolderPath(result.path);
    if (!mounted) return;
    setState(() => _gamesFolder = result.path);
    widget.onGamesFolderChanged();
  }

  Future<void> _requestAccess() async {
    await PermissionsService.requestStorageAccess();
    // Deliberately re-checks rather than assuming success: the request opens
    // the system Settings screen and returns immediately, so whether the user
    // actually granted anything is only knowable by asking again.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(4),
      children: [
        if (PermissionsService.isRelevant) _storageAccessCard(),
        _card(
          title: 'Games folder',
          body: _gamesFolder ?? 'Not set',
          bodyMuted: _gamesFolder == null,
          note: 'Scanned one level deep. Each subfolder holding EXE files is '
              'one game; loose CD and disk images are titles in their own '
              'right.',
          action: TextButton(
            onPressed: _pickGamesFolder,
            child: Text(_gamesFolder == null ? 'Choose' : 'Change'),
          ),
        ),
        if (StorageAccess.instance.kind == StorageStrategyKind.fileImport)
          _card(
            title: 'Importing on this platform',
            body: 'Files must be imported into the app rather than read in '
                'place.',
            note: 'The sandbox on this platform does not allow scanning an '
                'arbitrary folder, so games are copied in instead.',
          ),
        _card(
          title: 'Setup wizard',
          body: 'Run the first-launch setup again.',
          action: TextButton(
            onPressed: widget.onRunSetupWizard,
            child: const Text('Run'),
          ),
        ),
      ],
    );
  }

  Widget _storageAccessCard() {
    final granted = _hasStorageAccess ?? false;
    return _card(
      title: 'Storage access',
      body: granted ? 'Granted' : 'Not granted',
      bodyMuted: !granted,
      note: granted
          ? null
          : 'Without all-files access the games folder can be picked but its '
              'contents cannot be read, so the library will look empty.',
      action: granted
          ? null
          : TextButton(onPressed: _requestAccess, child: const Text('Grant')),
    );
  }

  Widget _card({
    required String title,
    required String body,
    String? note,
    Widget? action,
    bool bodyMuted = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: RetroDosboxColors.cardFill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: RetroDosboxColors.cardStroke),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: bodyMuted
                        ? RetroDosboxColors.warning
                        : RetroDosboxColors.textMuted2,
                    fontSize: 12,
                  ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 6),
                  Text(note, style: RetroDosboxTextStyles.statusLine),
                ],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
