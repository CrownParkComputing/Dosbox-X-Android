import 'dart:io';

import 'package:flutter/material.dart';

import '../data/source_collection.dart';

/// The collection browser: a set folder of thousands of DOS game zips,
/// searched and filtered inside the app. Pops with the imported game's
/// Directory, or null.
class GameBrowserScreen extends StatefulWidget {
  const GameBrowserScreen({super.key, required this.gamesDir});

  final String gamesDir;

  @override
  State<GameBrowserScreen> createState() => _GameBrowserScreenState();
}

class _GameBrowserScreenState extends State<GameBrowserScreen> {
  static const Color _amber = Color(0xFFFFB000);
  static const Color _cyan = Color(0xFF55FFFF);
  static const double _rowExtent = 52;

  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();

  String? _folder;
  List<SourceEntry> _all = <SourceEntry>[];
  String _query = '';
  String? _letter; // null = every letter
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    String? name = await SourceCollection.folderName();
    name ??= await SourceCollection.pickFolder();
    if (name == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final List<SourceEntry> entries = await SourceCollection.list();
    if (!mounted) return;
    setState(() {
      _folder = name;
      _all = entries;
      _loading = false;
    });
  }

  Future<void> _changeFolder() async {
    final String? name = await SourceCollection.pickFolder();
    if (name == null) return;
    setState(() => _loading = true);
    final List<SourceEntry> entries = await SourceCollection.list();
    if (!mounted) return;
    setState(() {
      _folder = name;
      _all = entries;
      _letter = null;
      _loading = false;
    });
  }

  List<SourceEntry> get _shown {
    final String q = _query.toLowerCase();
    return <SourceEntry>[
      for (final SourceEntry e in _all)
        if ((_letter == null || e.letter == _letter) &&
            (q.isEmpty || e.name.toLowerCase().contains(q)))
          e,
    ];
  }

  Future<void> _pick(SourceEntry entry) async {
    final String title = entry.name.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        content: Row(
          children: <Widget>[
            const CircularProgressIndicator(color: _amber),
            const SizedBox(width: 20),
            Expanded(child: Text('Adding $title...')),
          ],
        ),
      ),
    );
    final Directory? added =
        await SourceCollection.import(entry, widget.gamesDir);
    if (!mounted) return;
    Navigator.pop(context); // the progress dialog
    if (added == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add $title.')),
      );
      return;
    }
    Navigator.pop(context, added); // back to the shelf with the new game
  }

  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final List<SourceEntry> shown = _shown;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _folder == null ? 'COLLECTION' : 'COLLECTION - ${_folder!.toUpperCase()}',
          style: const TextStyle(letterSpacing: 2, color: _amber, fontSize: 16),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Choose a different folder',
            icon: const Icon(Icons.drive_folder_upload),
            onPressed: _changeFolder,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _amber))
          : Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    controller: _search,
                    onChanged: (String v) => setState(() => _query = v),
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, color: _cyan),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                      hintText:
                          'Search ${_all.length} games...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '${shown.length} SHOWN',
                        style: const TextStyle(
                            fontSize: 11, color: _cyan, letterSpacing: 1),
                      ),
                      const Spacer(),
                      if (_letter != null)
                        ActionChip(
                          label: Text('${_letter!} ✕'),
                          onPressed: () => setState(() => _letter = null),
                        ),
                    ],
                  ),
                ),
                _LetterBar(
                  selected: _letter,
                  onLetter: (String? l) => setState(() {
                    _letter = l;
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  }),
                ),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: shown.isEmpty
                            ? const Center(
                                child: Text('Nothing matches.',
                                    style:
                                        TextStyle(fontFamily: 'monospace')))
                            : ListView.builder(
                                controller: _scroll,
                                itemExtent: _rowExtent,
                                itemCount: shown.length,
                                itemBuilder:
                                    (BuildContext context, int index) {
                                  final SourceEntry e = shown[index];
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.folder_zip,
                                        color: _amber, size: 20),
                                    title: Text(
                                      e.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 13),
                                    ),
                                    trailing: Text(
                                      _sizeLabel(e.size),
                                      style: const TextStyle(
                                          fontSize: 11, color: _cyan),
                                    ),
                                    onTap: () => _pick(e),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// The A-Z bar: one bold button per letter, tap to filter, tap again to
/// clear. '#' collects digits and symbols. Sized for thumbs, not styluses.
class _LetterBar extends StatelessWidget {
  const _LetterBar({required this.selected, required this.onLetter});

  final String? selected;
  final ValueChanged<String?> onLetter;

  static const List<String> _letters = <String>[
    '#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: <Widget>[
          for (final String l in _letters)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Material(
                color: l == selected
                    ? const Color(0xFFFFB000)
                    : const Color(0xFF16164A),
                borderRadius: BorderRadius.circular(4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => onLetter(l == selected ? null : l),
                  child: SizedBox(
                    width: 40,
                    child: Center(
                      child: Text(
                        l,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: l == selected
                              ? const Color(0xFF0A0A2A)
                              : const Color(0xFF55FFFF),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
