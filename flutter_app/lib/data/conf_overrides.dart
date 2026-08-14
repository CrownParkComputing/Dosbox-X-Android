import 'dart:convert';
import 'dart:io';

/// What the user changed, and only that.
///
/// The conf the launcher writes carries overrides plus the autoexec; every
/// unchanged option is left to the core's own defaults, so a core upgrade
/// improves settings the user never touched instead of being pinned to the
/// values of the version that wrote the file.
class ConfOverrides {
  ConfOverrides(this._values);

  /// section -> key -> value
  final Map<String, Map<String, String>> _values;

  String? valueOf(String section, String key) => _values[section]?[key];

  bool get isEmpty => _values.isEmpty;

  int get count =>
      _values.values.fold(0, (int n, Map<String, String> s) => n + s.length);

  void set(String section, String key, String value) {
    (_values[section] ??= <String, String>{})[key] = value;
  }

  void clear(String section, String key) {
    final Map<String, String>? s = _values[section];
    if (s == null) return;
    s.remove(key);
    if (s.isEmpty) _values.remove(section);
  }

  Map<String, Map<String, String>> get bySection =>
      Map<String, Map<String, String>>.unmodifiable(_values);

  String encode() => const JsonEncoder.withIndent(' ').convert(_values);

  static ConfOverrides decode(String text) {
    final Map<String, dynamic> raw = jsonDecode(text) as Map<String, dynamic>;
    return ConfOverrides(raw.map((String s, dynamic keys) => MapEntry(
        s,
        (keys as Map<String, dynamic>)
            .map((String k, dynamic v) => MapEntry(k, v as String)))));
  }

  static ConfOverrides empty() => ConfOverrides(<String, Map<String, String>>{});

  static Future<File> _file(String dirPath) async =>
      File('$dirPath/conf_overrides.json');

  static Future<ConfOverrides> load(String dirPath) async {
    try {
      final File f = await _file(dirPath);
      if (!f.existsSync()) return empty();
      return decode(f.readAsStringSync());
    } on Object {
      // An unreadable overrides file must not brick settings; the user
      // re-changes what they cared about.
      return empty();
    }
  }

  Future<void> save(String dirPath) async {
    final File f = await _file(dirPath);
    final File tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(encode(), flush: true);
    tmp.renameSync(f.path);
  }
}
