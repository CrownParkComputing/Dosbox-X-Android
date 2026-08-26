// The games list: search, letter filter, and a measured grid of cards.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/game_entry.dart';
import '../services/app_prefs.dart';
import '../services/retrodosbox_conf_builder.dart';
import '../theme/retrodosbox_theme.dart';
import '../widgets/media_card.dart';

class LibraryGrid extends StatefulWidget {
  final List<GameEntry> entries;

  /// Paths that matched but could not be read. Reported in the status line
  /// because on Android this is what a scoped-storage permission problem looks
  /// like, and a quietly half-empty library is much harder to diagnose.
  final List<String> unreadable;

  final void Function(GameEntry entry) onLaunch;

  /// Long-press / secondary action, for the per-title settings sheet.
  final void Function(GameEntry entry)? onShowDetails;

  final VoidCallback? onRescan;

  /// Adds a new title to the library. The implementation opens a file picker
  /// for a zip or folder, copies it into the games folder, and triggers a
  /// rescan. Null is fine on platforms where this is not supported (but
  /// today it is on every supported platform).
  final VoidCallback? onAddGame;

  const LibraryGrid({
    super.key,
    required this.entries,
    required this.onLaunch,
    this.unreadable = const <String>[],
    this.onShowDetails,
    this.onRescan,
    this.onAddGame,
  });

  @override
  State<LibraryGrid> createState() => _LibraryGridState();
}

class _LibraryGridState extends State<LibraryGrid> {
  String _query = '';

  /// Search waits for the typing to pause: filtering per keystroke walks
  /// the whole library once per character, which reads as a stiff keyboard
  /// on a large collection -- the lesson the Amiga library learned.
  Timer? _searchDebounce;

  /// Cached derivations, recomputed only when their inputs change --
  /// getters called from build() re-walked the list on every frame.
  List<GameEntry> _filteredCache = const [];
  List<String> _lettersCache = const [];

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  @override
  void didUpdateWidget(LibraryGrid old) {
    super.didUpdateWidget(old);
    if (!identical(old.entries, widget.entries)) _recompute();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _recompute() {
    _filteredCache = _filter();
    _lettersCache = _letters();
  }

  void _setQuery(String v) {
    _query = v;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(_recompute);
    });
  }

  /// null means "All letters". Otherwise the first letter the title must
  /// start with (case-insensitive). Shown above the grid as A-Z tiles so the
  /// user can jump straight to a section of a large collection without
  /// typing.
  String? _letterFilter;

  List<GameEntry> _filter() {
    final q = _query.trim().toLowerCase();
    final letter = _letterFilter;
    return widget.entries.where((e) {
      if (letter != null) {
        final first = e.title.isEmpty ? '' : e.title[0].toLowerCase();
        // '#' is the catch-all bucket: digits (0-9) and any other
        // non-alphabetic first character. A separate tile per digit would
        // dominate the row in a collection that starts with "1", "2", "3"...
        // and "007" without giving the user any meaningful filtering.
        if (letter == '#') {
          final isAlpha = first.length == 1 &&
              first.codeUnitAt(0) >= 0x61 &&
              first.codeUnitAt(0) <= 0x7A;
          if (isAlpha) return false;
        } else if (first != letter) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      return e.title.toLowerCase().contains(q);
    }).toList(growable: false);
  }

  /// The letters actually used by the titles, plus a single '#' tile for
  /// everything that does not start with a letter (digits 0-9 and any
  /// non-alphabetic first character). A separate tile per digit would
  /// dominate the row for collections that begin with year-prefixed titles
  /// ("1...", "2...", "007...") without buying the user any useful
  /// filtering, so all of them collapse into '#'.
  List<String> _letters() {
    final hasAlpha = <String>{};
    var hasDigit = false;
    var hasOther = false;
    for (final e in widget.entries) {
      if (e.title.isEmpty) continue;
      final c = e.title[0].toLowerCase();
      final code = c.codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7A) {
        hasAlpha.add(c);
      } else if (code >= 0x30 && code <= 0x39) {
        hasDigit = true;
      } else {
        hasOther = true;
      }
    }
    const order = '#abcdefghijklmnopqrstuvwxyz';
    final result = <String>[];
    if (hasDigit || hasOther) result.add('#');
    for (final l in order.substring(1).split('')) {
      if (hasAlpha.contains(l)) result.add(l);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredCache;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchRow(),
        const SizedBox(height: 8),
        if (_lettersCache.length > 1) _letterRow(),
        _statusLine(filtered.length),
        const SizedBox(height: 4),
        Expanded(
          child: filtered.isEmpty ? _emptyState() : _grid(filtered),
        ),
      ],
    );
  }

  Widget _searchRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            onChanged: _setQuery,
            style: const TextStyle(fontSize: 13, color: Colors.white),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search',
              hintStyle: const TextStyle(color: RetroDosboxColors.textMuted),
              prefixIcon: const Icon(Icons.search,
                  size: 18, color: RetroDosboxColors.textMuted),
              filled: true,
              fillColor: RetroDosboxColors.cardFill,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: RetroDosboxColors.cardStroke),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: RetroDosboxColors.cardStroke),
              ),
            ),
          ),
        ),
        if (widget.onAddGame != null) ...[
          const SizedBox(width: 8),
          IconButton(
            onPressed: widget.onAddGame,
            icon: const Icon(Icons.add, size: 20),
            color: RetroDosboxColors.textMuted2,
            tooltip: 'Add a game (zip or folder)',
          ),
        ],
        if (widget.onRescan != null) ...[
          const SizedBox(width: 4),
          IconButton(
            onPressed: widget.onRescan,
            icon: const Icon(Icons.refresh, size: 20),
            color: RetroDosboxColors.textMuted2,
            tooltip: 'Rescan games folder',
          ),
        ],
      ],
    );
  }

  Widget _letterRow() {
    final letters = _lettersCache;
    return SizedBox(
      height: 26,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        children: [
          for (final l in letters) ...[
            _LetterChip(
              label: l == '#' ? '#' : l.toUpperCase(),
              selected: _letterFilter == l,
              onTap: () => setState(() {
                _letterFilter = _letterFilter == l ? null : l;
                _recompute();
              }),
            ),
            const SizedBox(width: 4),
          ],
          if (_letterFilter != null)
            _LetterChip(
              label: '×',
              selected: false,
              onTap: () => setState(() {
                _letterFilter = null;
                _recompute();
              }),
              tooltip: 'Clear letter filter',
            ),
        ],
      ),
    );
  }

  Widget _statusLine(int shown) {
    final total = widget.entries.length;
    final parts = <String>[
      shown == total ? '$total titles' : '$shown of $total titles',
    ];
    if (widget.unreadable.isNotEmpty) {
      parts.add('${widget.unreadable.length} unreadable');
    }
    return Text(
      parts.join('  -  '),
      style: TextStyle(
        fontSize: 11,
        color: widget.unreadable.isEmpty
            ? RetroDosboxColors.textMuted
            : RetroDosboxColors.warning,
      ),
    );
  }

  Widget _emptyState() {
    // Two genuinely different situations that must not look the same: an
    // empty library (set up your games folder) versus a filter that excludes
    // everything (clear the filter).
    final filtering = _query.trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtering ? Icons.filter_alt_off : Icons.folder_open,
              size: 40,
              color: RetroDosboxColors.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              filtering
                  ? 'No titles match this search.'
                  : 'No games found.',
              style: const TextStyle(color: RetroDosboxColors.textMuted2),
            ),
            const SizedBox(height: 6),
            Text(
              filtering
                  ? 'Try clearing the search or the letter filter.'
                  : 'Point the app at a folder of DOS games in Paths, then '
                      'rescan. A game is normally a folder containing its '
                      'EXE files, or a CD image.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: RetroDosboxColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// Long-press on a card: the per-title actions. Settings keeps the
  /// existing per-game sheet; Rename and Delete act on the file or folder
  /// itself and rescan.
  Future<void> _showEntryActions(GameEntry entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: RetroDosboxColors.cardFill,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(entry.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Colors.white38)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Play'),
              onTap: () => Navigator.pop(context, 'play'),
            ),
            if (widget.onShowDetails != null)
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Game settings'),
                onTap: () => Navigator.pop(context, 'settings'),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'play':
        widget.onLaunch(entry);
      case 'settings':
        widget.onShowDetails?.call(entry);
      case 'rename':
        await _renameEntry(entry);
      case 'delete':
        await _deleteEntry(entry);
    }
  }

  Future<void> _renameEntry(GameEntry entry) async {
    final controller = TextEditingController(text: p.basename(entry.path));
    final newName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Rename')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || !mounted) return;
    try {
      final target = p.join(p.dirname(entry.path), newName);
      if (File(target).existsSync() || Directory(target).existsSync()) {
        throw const FileSystemException('that name already exists');
      }
      final isDir = Directory(entry.path).existsSync();
      if (isDir) {
        await Directory(entry.path).rename(target);
      } else {
        await File(entry.path).rename(target);
      }
      widget.onRescan?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not rename: $e')));
    }
  }

  Future<void> _deleteEntry(GameEntry entry) async {
    if (await AppPrefs.getConfirmDelete()) {
      if (!mounted) return;
      final sure = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Delete this game?'),
          content: Text('${p.basename(entry.path)} will be deleted from '
              'disk -- the whole folder if it is one. This cannot be '
              'undone.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete')),
          ],
        ),
      );
      if (sure != true) return;
    }
    if (!mounted) return;
    try {
      final dir = Directory(entry.path);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      } else {
        await File(entry.path).delete();
      }
      widget.onRescan?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  Widget _grid(List<GameEntry> entries) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Measured rather than a fixed count: this app runs on phones,
        // handhelds and desktop windows, and a fixed column count is wrong on
        // all but one of them.
        final columns =
            (constraints.maxWidth / RetroDosboxMetrics.mediaCardCell).floor().clamp(1, 12);
        return GridView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio:
                RetroDosboxMetrics.mediaCardWidth / RetroDosboxMetrics.mediaCardHeight,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return GestureDetector(
              onLongPress: () => _showEntryActions(entry),
              child: MediaCard(
                title: entry.title,
                kindLabel: entry.kindLabel,
                subtitle: _subtitleFor(entry),
                onTap: () => widget.onLaunch(entry),
              ),
            );
          },
        );
      },
    );
  }

  /// A short line describing what will happen on launch, which is not obvious
  /// from a DOS title's name alone.
  static String? _subtitleFor(GameEntry entry) {
    switch (entry.kind) {
      case GameKind.dosFolder:
        final launcher = entry.preferredLauncher;
        if (launcher == null) return 'DOS prompt';
        final discs = entry.discs.length;
        final name = launcher.split(RegExp(r'[/\\]')).last;
        return discs == 0 ? name : '$name  +$discs disc';
      case GameKind.discImage:
        final extra = entry.discs.length;
        return extra == 0 ? 'Disc' : '${extra + 1} discs';
      case GameKind.floppyImage:
        return 'Boots FreeDOS demo';
      case GameKind.bootImage:
        // An installed Windows says so up front. It will not be booted here
        // (see WhyNotWindowsScreen), and a title that silently hangs is a far
        // worse answer than one that explains itself before it is tapped.
        return RetroDosboxConfBuilder.looksLikeInstalledWindows(entry)
            ? 'Windows image - not supported'
            : 'Boots MS-DOS';
      case GameKind.archive:
        // Archives are launched in place via ZipRunner; the user does not
        // need to import them first. The subtitle used to be "Needs
        // importing" -- that is the only message that fit when archives
        // were unlaunchable, and is now misleading.
        return 'Plays from zip';
    }
  }
}

class _LetterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  const _LetterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final chip = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? RetroDosboxColors.selectedFill : RetroDosboxColors.cardFill,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color:
                selected ? RetroDosboxColors.selectedStroke : RetroDosboxColors.cardStroke,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? Colors.white : RetroDosboxColors.textMuted,
          ),
        ),
      ),
    );
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}
