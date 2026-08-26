// save_states_screen.dart — The States tab: every named save, newest
// first, with pictures. Tap to go back to that moment; long-press to
// forget it. The Saturn front end's shape.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/save_state_service.dart';
import '../theme/retrodosbox_theme.dart';

class SaveStatesScreen extends StatefulWidget {
  final Future<void> Function(SaveStateEntry entry) onResume;

  const SaveStatesScreen({super.key, required this.onResume});

  @override
  State<SaveStatesScreen> createState() => _SaveStatesScreenState();
}

class _SaveStatesScreenState extends State<SaveStatesScreen> {
  List<SaveStateEntry> _entries = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final entries = await SaveStateService.list();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loaded = true;
    });
  }

  Future<void> _forget(SaveStateEntry entry) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Forget this save?'),
        content: Text('${entry.title} — slot ${entry.slot}, '
            '${entry.ageDescription}. The engine\'s slot file stays on '
            'disk until the slot is reused; only the card goes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await SaveStateService.forget(entry);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.save_outlined,
                  size: 40, color: RetroDosboxColors.textMuted),
              SizedBox(height: 12),
              Text(
                'No saved states yet.\n\nWhile playing, the Save tool on '
                'the right-hand rail keeps your place here, with a '
                'picture.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: RetroDosboxColors.textMuted2, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(builder: (context, constraints) {
        final columns = (constraints.maxWidth / 240).floor().clamp(1, 6);
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 4 / 3.6,
          ),
          itemCount: _entries.length,
          itemBuilder: (context, i) {
            final e = _entries[i];
            return _StateCard(
              entry: e,
              onTap: () => unawaited(widget.onResume(e)),
              onLongPress: () => unawaited(_forget(e)),
            );
          },
        );
      }),
    );
  }
}

class _StateCard extends StatelessWidget {
  final SaveStateEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _StateCard({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = entry.thumbnailPath;
    return Material(
      color: RetroDosboxColors.cardFill,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: thumb != null && File(thumb).existsSync()
                  ? Image.file(File(thumb), fit: BoxFit.cover)
                  : const ColoredBox(
                      color: Colors.black26,
                      child: Icon(Icons.videogame_asset,
                          size: 36, color: RetroDosboxColors.textMuted),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${entry.ageDescription}  ·  slot ${entry.slot}',
                      style: const TextStyle(
                          fontSize: 10,
                          color: RetroDosboxColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
