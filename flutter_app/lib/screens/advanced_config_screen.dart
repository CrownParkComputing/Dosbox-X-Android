import 'package:flutter/material.dart';

import '../data/conf_catalog.dart';
import '../data/conf_overrides.dart';

/// The complex GUI, refitted - and laid out like it means it.
///
/// Sections arrive grouped the way a person thinks about a PC - machine,
/// video, sound, input, storage, networking - as a card grid, not a wall of
/// 42 rows. Inside a section every option renders from the core's own
/// vocabulary: enums as dropdowns, booleans as switches, help underneath,
/// changed options marked in amber with one tap back to default. Search
/// spans all ~900 options from the top.
class AdvancedConfigScreen extends StatefulWidget {
  const AdvancedConfigScreen({
    super.key,
    required this.overrides,
    required this.onChanged,
  });

  final ConfOverrides overrides;
  final VoidCallback onChanged;

  @override
  State<AdvancedConfigScreen> createState() => _AdvancedConfigScreenState();
}

/// How a person thinks about a PC, mapped onto conf sections. Anything the
/// map does not claim lands in Esoterica rather than being hidden - this is
/// the complex GUI, nothing is off the menu.
class _Group {
  const _Group(this.title, this.icon, this.sections);

  final String title;
  final IconData icon;
  final List<String> sections;
}

const List<_Group> _groups = <_Group>[
  _Group('Machine', Icons.memory, <String>[
    'dosbox', 'cpu', 'keyboard', 'dos', 'config',
  ]),
  _Group('Video', Icons.desktop_windows, <String>[
    'sdl', 'render', 'video', 'vsync', 'voodoo', 'glide',
  ]),
  _Group('Sound', Icons.graphic_eq, <String>[
    'mixer', 'sblaster', 'gus', 'speaker', 'midi', 'innova', 'imfc',
  ]),
  _Group('Input', Icons.sports_esports, <String>[
    'joystick', 'mapper', 'autoexec',
  ]),
  _Group('Storage', Icons.save, <String>[
    'ide, primary', 'ide, secondary', 'ide, tertiary', 'ide, quaternary',
    'ide, quinternary', 'ide, sexternary', 'ide, septernary',
    'ide, octernary', 'fdc, primary', '4dos',
  ]),
  _Group('Ports & Network', Icons.settings_ethernet, <String>[
    'serial', 'parallel', 'printer', 'ne2000', 'ethernet, pcap',
    'ethernet, slirp', 'modem',
  ]),
  _Group('PC-98 & DOS/V', Icons.language, <String>['pc98', 'dosv', 'ttf']),
];

class _AdvancedConfigScreenState extends State<AdvancedConfigScreen> {
  ConfCatalog? _catalog;
  String _query = '';
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    ConfCatalog.load().then((ConfCatalog c) {
      if (mounted) setState(() => _catalog = c);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _set(String section, ConfOption option, String value) {
    if (value == option.defaultValue) {
      widget.overrides.clear(section, option.key);
    } else {
      widget.overrides.set(section, option.key, value);
    }
    widget.onChanged();
    setState(() {});
  }

  int _changedIn(ConfSection s) => s.options
      .where((ConfOption o) => widget.overrides.valueOf(s.name, o.key) != null)
      .length;

  @override
  Widget build(BuildContext context) {
    final ConfCatalog? catalog = _catalog;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'CONFIGURATION',
          style: TextStyle(fontFamily: 'monospace', letterSpacing: 3),
        ),
        actions: <Widget>[
          if (widget.overrides.count > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  '${widget.overrides.count} CHANGED',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: Color(0xFFFFB000),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: catalog == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Search all 899 settings…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      isDense: true,
                    ),
                    onChanged: (String q) =>
                        setState(() => _query = q.toLowerCase()),
                  ),
                ),
                Expanded(
                  child: _query.isEmpty
                      ? _groupGrid(catalog)
                      : _searchResults(catalog),
                ),
              ],
            ),
    );
  }

  Widget _groupGrid(ConfCatalog catalog) {
    final Map<String, ConfSection> byName = <String, ConfSection>{
      for (final ConfSection s in catalog.sections) s.name: s,
    };
    final Set<String> claimed = <String>{
      for (final _Group g in _groups) ...g.sections,
    };
    final List<ConfSection> esoterica = <ConfSection>[
      for (final ConfSection s in catalog.sections)
        if (!claimed.contains(s.name)) s,
    ];

    final List<Widget> cards = <Widget>[
      for (final _Group g in _groups)
        _groupCard(
          g.title,
          g.icon,
          <ConfSection>[
            for (final String name in g.sections)
              if (byName.containsKey(name)) byName[name]!,
          ],
        ),
      if (esoterica.isNotEmpty)
        _groupCard('Esoterica', Icons.science, esoterica),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 340).floor().clamp(1, 4);
        return GridView.count(
          padding: const EdgeInsets.all(12),
          crossAxisCount: columns,
          childAspectRatio: 1.55,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          children: cards,
        );
      },
    );
  }

  Widget _groupCard(String title, IconData icon, List<ConfSection> sections) {
    final int options =
        sections.fold(0, (int n, ConfSection s) => n + s.options.length);
    final int changed =
        sections.fold(0, (int n, ConfSection s) => n + _changedIn(s));
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: changed > 0
              ? const Color(0xFFFFB000)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: InkWell(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => _GroupScreen(
              title: title,
              sections: sections,
              overrides: widget.overrides,
              onSet: _set,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(icon, color: const Color(0xFF55FFFF), size: 22),
                  const Spacer(),
                  if (changed > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFB000),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$changed',
                        style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 12),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${sections.length} sections · $options options',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchResults(ConfCatalog catalog) {
    final List<(ConfSection, ConfOption)> hits = <(ConfSection, ConfOption)>[
      for (final ConfSection s in catalog.sections)
        for (final ConfOption o in s.options)
          if (o.key.toLowerCase().contains(_query) ||
              o.help.toLowerCase().contains(_query))
            (s, o),
    ];
    return ListView.builder(
      itemCount: hits.length,
      itemBuilder: (BuildContext context, int i) {
        final (ConfSection section, ConfOption option) = hits[i];
        return OptionTile(
          section: section.name,
          option: option,
          current: widget.overrides.valueOf(section.name, option.key),
          onSet: (String v) => _set(section.name, option, v),
          showSection: true,
        );
      },
    );
  }
}

/// One themed group: its sections as tabs across the top, so [cpu] and
/// [dosbox] sit a swipe apart instead of a navigation stack apart.
class _GroupScreen extends StatelessWidget {
  const _GroupScreen({
    required this.title,
    required this.sections,
    required this.overrides,
    required this.onSet,
  });

  final String title;
  final List<ConfSection> sections;
  final ConfOverrides overrides;
  final void Function(String section, ConfOption option, String value) onSet;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: sections.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            title.toUpperCase(),
            style: const TextStyle(
                fontFamily: 'monospace', letterSpacing: 2, fontSize: 16),
          ),
          bottom: TabBar(
            isScrollable: true,
            tabs: <Widget>[
              for (final ConfSection s in sections)
                Tab(
                  child: Text(
                    '[${s.name}]',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            for (final ConfSection s in sections) _SectionList(
              section: s,
              overrides: overrides,
              onSet: onSet,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionList extends StatefulWidget {
  const _SectionList({
    required this.section,
    required this.overrides,
    required this.onSet,
  });

  final ConfSection section;
  final ConfOverrides overrides;
  final void Function(String section, ConfOption option, String value) onSet;

  @override
  State<_SectionList> createState() => _SectionListState();
}

class _SectionListState extends State<_SectionList> {
  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: widget.section.options.length,
      separatorBuilder: (BuildContext context, int i) => Divider(
        height: 1,
        color: Colors.white.withValues(alpha: 0.05),
        indent: 16,
        endIndent: 16,
      ),
      itemBuilder: (BuildContext context, int i) {
        final ConfOption option = widget.section.options[i];
        return OptionTile(
          section: widget.section.name,
          option: option,
          current: widget.overrides.valueOf(widget.section.name, option.key),
          onSet: (String v) {
            widget.onSet(widget.section.name, option, v);
            setState(() {});
          },
        );
      },
    );
  }
}

class OptionTile extends StatelessWidget {
  const OptionTile({
    super.key,
    required this.section,
    required this.option,
    required this.current,
    required this.onSet,
    this.showSection = false,
  });

  final String section;
  final ConfOption option;
  final String? current;
  final ValueChanged<String> onSet;
  final bool showSection;

  @override
  Widget build(BuildContext context) {
    final String effective = current ?? option.defaultValue;
    final bool changed = current != null;

    Widget control;
    if (option.isBool) {
      control = Switch(
        value: effective.toLowerCase() == 'true' || effective == '1',
        activeThumbColor: const Color(0xFFFFB000),
        onChanged: (bool v) => onSet(v ? 'true' : 'false'),
      );
    } else if (option.isEnum) {
      control = DropdownButton<String>(
        value: option.values.contains(effective) ? effective : null,
        hint: Text(effective, style: const TextStyle(fontFamily: 'monospace')),
        underline: const SizedBox.shrink(),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        items: <DropdownMenuItem<String>>[
          for (final String v in option.values)
            DropdownMenuItem<String>(value: v, child: Text(v)),
        ],
        onChanged: (String? v) {
          if (v != null) onSet(v);
        },
      );
    } else {
      control = SizedBox(
        width: 150,
        child: TextFormField(
          initialValue: effective,
          textAlign: TextAlign.end,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            border: UnderlineInputBorder(),
          ),
          onFieldSubmitted: onSet,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        showSection
                            ? '[$section] ${option.key}'
                            : option.key,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                          color: changed
                              ? const Color(0xFFFFB000)
                              : Colors.white,
                        ),
                      ),
                    ),
                    if (changed)
                      IconButton(
                        icon: const Icon(Icons.settings_backup_restore,
                            size: 16),
                        color: const Color(0xFF55FFFF),
                        tooltip: 'Back to default (${option.defaultValue})',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onSet(option.defaultValue),
                      ),
                  ],
                ),
                if (option.help.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Text(
                      option.help,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          control,
        ],
      ),
    );
  }
}
