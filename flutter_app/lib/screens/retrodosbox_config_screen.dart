// DOSBox-X configuration tab.
//
// This screen has no equivalent in the VICE front end, and it is not a
// hand-written list of settings. Everything on it is generated from what the
// running engine reflects back through RetroDosboxCore.configSections() and
// configSectionProperties(): the name, type, current value, default, help text
// and legal values of every property DOSBox-X itself knows about.
//
// That is a deliberate replacement for the Java app's DosConfigActivity, which
// hardcoded a subset of properties and went stale every time DOSBox-X gained
// or renamed one. Reflecting the engine's own config system means this screen
// is correct by construction for whatever core it is linked against, at the
// cost of the UI being generic -- which is why the per-property help text is
// shown rather than hidden behind a tap.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ffi/retrodosbox_core.dart';
import '../services/engine_config.dart';
import '../theme/retrodosbox_theme.dart';

class RetroDosboxConfigScreen extends StatefulWidget {
  /// Where the engine's configuration lives.
  ///
  /// Not the core object: on Android the engine is in another process and the
  /// launcher's core is an idle handle that reports no sections at all, which
  /// is why this screen used to say "No running session" over a running game.
  /// See EngineConfig.
  final EngineConfig config;

  const RetroDosboxConfigScreen({super.key, required this.config});

  @override
  State<RetroDosboxConfigScreen> createState() => _DosConfigScreenState();
}

class _DosConfigScreenState extends State<RetroDosboxConfigScreen> {
  List<String> _sections = const [];
  String? _section;
  List<RetroDosboxConfigProperty> _properties = const [];

  /// Text controllers for the free-text properties of the CURRENT section
  /// only, keyed by property name. Held rather than created inline because a
  /// fresh controller on every build would reset the caret to position zero
  /// after each keystroke.
  final Map<String, TextEditingController> _controllers = {};

  /// Properties the engine refused to change while running. DOSBox-X rejects
  /// plenty of them by design (machine type, memory size and so on can only
  /// be applied at boot), so this is recorded per property and shown as a
  /// quiet inline note -- not a dialog, and not an error, because for these
  /// properties refusal is the correct behaviour.
  final Set<String> _rejected = {};

  /// Transient result of the last "Save to config file" press.
  String? _saveMessage;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    _reloadSections();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _reloadSections() async {
    final sections = await widget.config.sections();
    if (!mounted) return;
    setState(() {
      _sections = sections;
      // Keep the current selection across a refresh when it still exists,
      // so pressing Refresh does not throw the user back to the first
      // section every time.
      if (_section == null || !sections.contains(_section)) {
        _section = sections.isEmpty ? null : sections.first;
      }
    });
    await _reloadProperties();
  }

  Future<void> _reloadProperties() async {
    final section = _section;
    final props = section == null
        ? const <RetroDosboxConfigProperty>[]
        : await widget.config.properties(section);
    if (!mounted) return;
    _disposeControllers();
    setState(() => _properties = props);
  }

  void _disposeControllers() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }

  TextEditingController _controllerFor(RetroDosboxConfigProperty property) {
    final existing = _controllers[property.name];
    if (existing != null) return existing;
    final created = TextEditingController(text: property.value);
    _controllers[property.name] = created;
    return created;
  }

  void _selectSection(String section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _rejected.clear();
      _saveMessage = null;
    });
    unawaited(_reloadProperties());
  }

  /// Applies one property and re-reads the section, so what is on screen is
  /// always the engine's opinion of the value rather than the one typed --
  /// DOSBox-X normalises some values (case, units, clamped ranges) even when
  /// it accepts them.
  Future<void> _apply(RetroDosboxConfigProperty property, String value) async {
    final section = _section;
    if (section == null) return;
    final ok = await widget.config.set(section, property.name, value);
    if (!mounted) return;
    setState(() {
      if (ok) {
        _rejected.remove(property.name);
      } else {
        _rejected.add(property.name);
      }
    });
    await _reloadProperties();
  }

  Future<void> _save() async {
    final ok = await widget.config.save();
    if (!mounted) return;
    setState(() {
      _saveFailed = !ok;
      _saveMessage = ok
          ? 'Configuration written to the active .conf file.'
          : widget.config.canSave
              ? 'The engine could not write the config file. Settings you '
                  'have changed are still live for this session.'
              // The engine is in another process and nothing comes back from
              // it, so claiming a successful write would be a guess.
              : 'Saving to the .conf file is not available while the engine '
                  'runs in its own process. Your changes are live for this '
                  'session; set them per title to make them stick.';
    });
  }

  Widget _card({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: RetroDosboxColors.cardFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: RetroDosboxColors.cardStroke),
        ),
        child: child,
      ),
    );
  }

  Widget _propertyEditor(RetroDosboxConfigProperty property) {
    if (property.isBool) {
      // DOSBox-X spells booleans "true"/"false" in its config, so that is
      // what goes back to configSet -- not Dart's bool.toString() by luck,
      // but explicitly, because the two only happen to agree.
      final on = property.value.toLowerCase() == 'true' ||
          property.value == '1' ||
          property.value.toLowerCase() == 'on';
      return Switch(
        value: on,
        activeThumbColor: RetroDosboxColors.accentAmber,
        onChanged: (v) => unawaited(_apply(property, v ? 'true' : 'false')),
      );
    }

    if (property.isEnum) {
      // The engine's current value is not always one of the offered values
      // (a few properties accept free text as well as named constants), and
      // a DropdownButton whose value is absent from its items throws. Offer
      // the current value as an extra entry in that case.
      final items = <String>[
        ...property.values,
        if (!property.values.contains(property.value)) property.value,
      ];
      return DropdownButton<String>(
        value: property.value,
        isDense: true,
        dropdownColor: RetroDosboxColors.cardFill,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        underline: Container(height: 1, color: RetroDosboxColors.cardStroke),
        items: [
          for (final value in items)
            DropdownMenuItem(
              value: value,
              child: Text(value.isEmpty ? '(empty)' : value),
            ),
        ],
        onChanged: (v) {
          if (v == null) return;
          unawaited(_apply(property, v));
        },
      );
    }

    // Free text. The keyboard hint is chosen from the reflected type so a
    // numeric property does not bring up a full alphabetic keyboard on a
    // phone. 'hex' stays a plain text keyboard because hex digits include
    // a-f, which a number keyboard cannot produce.
    final numeric = property.type == 'int' || property.type == 'double';
    return SizedBox(
      width: 150,
      child: TextField(
        controller: _controllerFor(property),
        style: const TextStyle(color: Colors.white, fontSize: 13),
        keyboardType: numeric
            ? TextInputType.numberWithOptions(
                decimal: property.type == 'double',
                signed: true,
              )
            : TextInputType.text,
        inputFormatters: property.type == 'int'
            ? [FilteringTextInputFormatter.allow(RegExp(r'[-0-9]'))]
            : null,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: RetroDosboxColors.cardStroke),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: RetroDosboxColors.accentAmber),
          ),
        ),
        // Committed on submit rather than on every keystroke: pushing a
        // half-typed number into the running engine would apply nonsense
        // values (and be rejected) on the way to the intended one.
        onSubmitted: (v) => unawaited(_apply(property, v)),
      ),
    );
  }

  Widget _propertyRow(RetroDosboxConfigProperty property) {
    final modified = property.value != property.defaultValue;
    final rejected = _rejected.contains(property.name);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            property.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (modified) ...[
                          const SizedBox(width: 8),
                          const Text('modified',
                              style: TextStyle(
                                  color: RetroDosboxColors.accentAmber,
                                  fontSize: 10,
                                  letterSpacing: 0.8)),
                        ],
                      ],
                    ),
                    if (property.help.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(property.help,
                          style: RetroDosboxTextStyles.statusLine
                              .copyWith(height: 1.35)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _propertyEditor(property),
            ],
          ),
          if (modified)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => unawaited(_apply(property, property.defaultValue)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Reset to default '
                  '(${property.defaultValue.isEmpty ? 'empty' : property.defaultValue})',
                  style: const TextStyle(
                      color: RetroDosboxColors.textMuted, fontSize: 11),
                ),
              ),
            ),
          if (rejected)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'The engine kept its current value for this property. Some '
                'settings can only be applied when the machine boots; change '
                'it and save, then restart the session.',
                style: RetroDosboxTextStyles.statusLine
                    .copyWith(color: RetroDosboxColors.warning),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('DOSBox-X Configuration',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: RetroDosboxColors.cardFill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: RetroDosboxColors.cardStroke),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('No running session',
                  style: TextStyle(
                      color: RetroDosboxColors.accentAmber,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'This screen is generated from the emulator\'s own '
                'configuration system, so it can only list properties while '
                'a machine is running. Start a game or a DOS prompt from the '
                'library and come back -- the full set of sections and '
                'properties for that session will appear here.',
                style: TextStyle(color: RetroDosboxColors.textMuted2, height: 1.4),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Check again'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: RetroDosboxColors.accentTeal,
                  side: const BorderSide(color: RetroDosboxColors.accentTeal),
                ),
                onPressed: () => unawaited(_reloadSections()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_sections.isEmpty) return _emptyState();

    final section = _section;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('DOSBox-X Configuration',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ),
              IconButton(
                tooltip: 'Re-read from the engine',
                icon: const Icon(Icons.refresh,
                    color: RetroDosboxColors.textMuted, size: 20),
                onPressed: _reloadSections,
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Live settings from the running engine. Changes take effect '
            'immediately where the emulator allows it; use Save to keep them '
            'in the session\'s .conf file.',
            style: TextStyle(color: RetroDosboxColors.textMuted2, fontSize: 12),
          ),
        ),
        _card(
          child: Row(
            children: [
              const Text('Section',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: section,
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: RetroDosboxColors.cardFill,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  underline: Container(height: 1, color: RetroDosboxColors.cardStroke),
                  items: [
                    for (final name in _sections)
                      DropdownMenuItem(value: name, child: Text('[$name]')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _selectSection(v);
                  },
                ),
              ),
            ],
          ),
        ),
        if (_properties.isEmpty)
          _card(
            child: const Text(
              'This section reflects no properties.',
              style: TextStyle(color: RetroDosboxColors.textMuted, fontSize: 12),
            ),
          )
        else
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < _properties.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: RetroDosboxColors.cardStroke),
                  _propertyRow(_properties[i]),
                ],
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save to config file'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: RetroDosboxColors.accentTeal,
                  side: const BorderSide(color: RetroDosboxColors.accentTeal),
                ),
                onPressed: _save,
              ),
            ],
          ),
        ),
        if (_saveMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              _saveMessage!,
              style: RetroDosboxTextStyles.statusLine.copyWith(
                color: _saveFailed ? RetroDosboxColors.warning : RetroDosboxColors.accentTeal,
              ),
            ),
          ),
      ],
    );
  }
}
