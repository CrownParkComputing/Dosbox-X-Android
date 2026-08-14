import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// The core's own configuration vocabulary: 42 sections, ~900 options,
/// extracted from dosbox-x.reference.full.conf at build time by
/// tools/gen-conf-catalog.py. The launcher renders ALL of it - this is the
/// complex GUI the app is known for, refitted - and never hand-maintains an
/// option list that upstream would immediately outgrow.
class ConfOption {
  const ConfOption({
    required this.key,
    required this.defaultValue,
    required this.help,
    required this.values,
  });

  final String key;
  final String defaultValue;
  final String help;

  /// Non-empty means an enumerated option (dropdown). Empty means free text
  /// unless the default reads as a boolean.
  final List<String> values;

  bool get isBool {
    final String d = defaultValue.toLowerCase();
    if (values.isNotEmpty) {
      final Set<String> lower =
          values.map((String v) => v.toLowerCase()).toSet();
      // Exactly the boolean family, not "auto, true, false" style enums.
      return lower.difference(<String>{'true', 'false', '1', '0'}).isEmpty;
    }
    return d == 'true' || d == 'false';
  }

  bool get isEnum => values.isNotEmpty && !isBool;

  static ConfOption fromJson(Map<String, dynamic> json) => ConfOption(
        key: json['key'] as String,
        defaultValue: json['default'] as String? ?? '',
        help: json['help'] as String? ?? '',
        values: (json['values'] as List<dynamic>? ?? <dynamic>[])
            .cast<String>(),
      );
}

class ConfSection {
  const ConfSection({required this.name, required this.options});

  final String name;
  final List<ConfOption> options;

  static ConfSection fromJson(Map<String, dynamic> json) => ConfSection(
        name: json['name'] as String,
        options: (json['options'] as List<dynamic>)
            .map((dynamic o) => ConfOption.fromJson(o as Map<String, dynamic>))
            .toList(),
      );
}

class ConfCatalog {
  const ConfCatalog(this.sections);

  final List<ConfSection> sections;

  static ConfCatalog? _cached;

  static Future<ConfCatalog> load() async {
    final ConfCatalog? cached = _cached;
    if (cached != null) return cached;
    final Map<String, dynamic> json = jsonDecode(
            await rootBundle.loadString('assets/conf_catalog.json'))
        as Map<String, dynamic>;
    final ConfCatalog catalog = ConfCatalog(
      (json['sections'] as List<dynamic>)
          .map((dynamic s) => ConfSection.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
    _cached = catalog;
    return catalog;
  }

  /// Parses catalogue JSON directly - the test seam, no asset bundle needed.
  static ConfCatalog fromJsonString(String text) {
    final Map<String, dynamic> json =
        jsonDecode(text) as Map<String, dynamic>;
    return ConfCatalog(
      (json['sections'] as List<dynamic>)
          .map((dynamic s) => ConfSection.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}
