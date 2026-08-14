import 'package:flutter/material.dart';

import '../data/conf_catalog.dart';
import '../data/conf_overrides.dart';

/// The complex GUI, refitted.
///
/// Every section and option the core knows, rendered from its own
/// vocabulary: enums as dropdowns, booleans as switches, the rest as text,
/// each with the core's help underneath. Changed options wear a badge and
/// only they are written to the conf - the rest stay the core's business.
/// Search spans all ~900 options, because nobody pages through 42 sections
/// for `cycles`.
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

class _AdvancedConfigScreenState extends State<AdvancedConfigScreen> {
  ConfCatalog? _catalog;
  String _query = '';

  @override
  void initState() {
    super.initState();
    ConfCatalog.load().then((ConfCatalog c) {
      if (mounted) setState(() => _catalog = c);
    });
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

  @override
  Widget build(BuildContext context) {
    final ConfCatalog? catalog = _catalog;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: InputDecoration(
            hintText: 'Search ${catalog == null ? '' : 'all settings'}',
            border: InputBorder.none,
            icon: const Icon(Icons.search),
          ),
          onChanged: (String q) => setState(() => _query = q.toLowerCase()),
        ),
        actions: <Widget>[
          if (widget.overrides.count > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('${widget.overrides.count} changed'),
              ),
            ),
        ],
      ),
      body: catalog == null
          ? const Center(child: CircularProgressIndicator())
          : _query.isEmpty
              ? _sectionList(catalog)
              : _searchResults(catalog),
    );
  }

  Widget _sectionList(ConfCatalog catalog) {
    return ListView.builder(
      itemCount: catalog.sections.length,
      itemBuilder: (BuildContext context, int i) {
        final ConfSection section = catalog.sections[i];
        final int changed = section.options
            .where((ConfOption o) =>
                widget.overrides.valueOf(section.name, o.key) != null)
            .length;
        return ListTile(
          title: Text('[${section.name}]'),
          subtitle: Text('${section.options.length} options'),
          trailing: changed > 0
              ? Badge(label: Text('$changed'))
              : const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => _SectionScreen(
                section: section,
                overrides: widget.overrides,
                onSet: _set,
              ),
            ),
          ),
        );
      },
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
        return _OptionTile(
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

class _SectionScreen extends StatefulWidget {
  const _SectionScreen({
    required this.section,
    required this.overrides,
    required this.onSet,
  });

  final ConfSection section;
  final ConfOverrides overrides;
  final void Function(String section, ConfOption option, String value) onSet;

  @override
  State<_SectionScreen> createState() => _SectionScreenState();
}

class _SectionScreenState extends State<_SectionScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('[${widget.section.name}]')),
      body: ListView.builder(
        itemCount: widget.section.options.length,
        itemBuilder: (BuildContext context, int i) {
          final ConfOption option = widget.section.options[i];
          return _OptionTile(
            section: widget.section.name,
            option: option,
            current:
                widget.overrides.valueOf(widget.section.name, option.key),
            onSet: (String v) {
              widget.onSet(widget.section.name, option, v);
              setState(() {});
            },
          );
        },
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.section,
    required this.option,
    required this.current,
    required this.onSet,
    this.showSection = false,
  });

  final String section;
  final ConfOption option;

  /// The override, or null when the core's default rules.
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
        onChanged: (bool v) => onSet(v ? 'true' : 'false'),
      );
    } else if (option.isEnum) {
      control = DropdownButton<String>(
        value: option.values.contains(effective) ? effective : null,
        hint: Text(effective),
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
        width: 140,
        child: TextFormField(
          initialValue: effective,
          textAlign: TextAlign.end,
          decoration: const InputDecoration(isDense: true),
          onFieldSubmitted: onSet,
        ),
      );
    }

    return ListTile(
      title: Row(
        children: <Widget>[
          if (changed)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.circle, size: 8, color: Colors.amberAccent),
            ),
          Expanded(
            child: Text(showSection ? '[$section] ${option.key}' : option.key),
          ),
        ],
      ),
      subtitle: option.help.isEmpty
          ? null
          : Text(
              option.help,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
      trailing: control,
      onLongPress: changed
          ? () => onSet(option.defaultValue) // back to the core's default
          : null,
    );
  }
}
