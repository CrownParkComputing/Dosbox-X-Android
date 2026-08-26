// Where the emulator's own configuration comes from, and goes to.
//
// RetroDosboxConfigScreen is generated from what the RUNNING engine reflects
// back -- every section, property, type, value, default, help string and set
// of legal values that DOSBox-X itself knows about. That works directly on
// desktop, where the engine is in this process.
//
// On Android it is in :dosbox, and the launcher's core object is an idle
// library handle that never started anything. Asked for its config it
// truthfully answered "no sections", so the screen showed "No running
// session" while a game was playing, and any change would have been written
// to a core with nothing in it. Input hit this same wall and was routed
// across the boundary; config never was.
//
// Reads and writes are asymmetric, so they cross differently:
//
//   WRITE  fire-and-forget down the existing input channel, exactly like a
//          keypress. Nothing comes back and nothing needs to.
//
//   READ   the engine PUBLISHES its whole config to a file in the app's own
//          support directory the moment a session starts, and the launcher
//          reads it there. Both processes are the same app, so that directory
//          is shared and needs no permission.
//
// The file rather than a reply channel is deliberate. Answering a query
// across a bound Messenger means request/response plumbing, a reply Messenger
// and a state machine for "asked but not yet answered". A dump written once
// per session has none of that, cannot deadlock, is inspectable with `cat`
// when something looks wrong, and is already correct by the time anyone opens
// the screen.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffi/retrodosbox_core.dart';
import '../ffi/retrodosbox_native_paths.dart';
import 'app_restart_service.dart';
import 'emulator_input.dart';

/// The engine's configuration, wherever the engine happens to be.
abstract class EngineConfig {
  factory EngineConfig.forSession({
    required RetroDosboxCore core,
    required EmulatorInput input,
  }) =>
      EmulatorProcess.isSupported
          ? _PublishedConfig(input)
          : _CoreConfig(core);

  /// Section names, or empty when no machine is running.
  Future<List<String>> sections();

  Future<List<RetroDosboxConfigProperty>> properties(String section);

  /// Applies a value. Returns false when it could not be delivered; on
  /// Android that is "the engine is not running", never "the engine refused",
  /// because nothing comes back to say so.
  Future<bool> set(String section, String property, String value);

  /// Writes the live settings back to the session's .conf file.
  ///
  /// Only meaningful where the engine is in this process. Across the boundary
  /// there is no way to hear whether the write succeeded, and reporting a
  /// success nobody verified would be worse than saying it is unavailable.
  Future<bool> save();

  /// Whether [save] can report a truthful answer here.
  bool get canSave;
}

/// Where the published config lives. Both processes derive it the same way.
Future<File> engineConfigDumpFile() async {
  final dir = await RetroDosboxNativePaths.confDir();
  return File(p.join(dir.path, 'engine-config.json'));
}

/// Called in the ENGINE process once a session is up: writes everything the
/// core knows about itself where the launcher can read it.
///
/// Best-effort by design. A failure here costs a settings screen, and must
/// never cost the session the user actually asked for.
Future<void> publishEngineConfig(RetroDosboxCore core) async {
  try {
    final sections = core.configSections();
    if (sections.isEmpty) return;
    final dump = <String, dynamic>{
      for (final section in sections)
        section: core
            .configSectionProperties(section)
            .map((prop) => <String, dynamic>{
                  'name': prop.name,
                  'type': prop.type,
                  'value': prop.value,
                  'default': prop.defaultValue,
                  'help': prop.help,
                  'values': prop.values,
                })
            .toList(growable: false),
    };
    final file = await engineConfigDumpFile();
    await file.writeAsString(jsonEncode(dump), flush: true);
  } on Object {
    // Nothing to do and nothing worth failing a launch over.
  }
}

/// Desktop: the engine is right here.
class _CoreConfig implements EngineConfig {
  _CoreConfig(this.core);
  final RetroDosboxCore core;

  @override
  Future<List<String>> sections() async => core.configSections();

  @override
  Future<List<RetroDosboxConfigProperty>> properties(String section) async =>
      core.configSectionProperties(section);

  @override
  Future<bool> set(String section, String property, String value) async =>
      core.configSet(section, property, value);

  @override
  Future<bool> save() async => core.configSave();

  @override
  bool get canSave => true;
}

/// Android: read what the engine published, write down the input channel.
class _PublishedConfig implements EngineConfig {
  _PublishedConfig(this.input);
  final EmulatorInput input;

  Map<String, List<RetroDosboxConfigProperty>>? _cache;

  Future<Map<String, List<RetroDosboxConfigProperty>>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final file = await engineConfigDumpFile();
      if (!file.existsSync()) return const {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const {};
      final parsed = <String, List<RetroDosboxConfigProperty>>{};
      decoded.forEach((section, props) {
        if (props is! List) return;
        parsed[section as String] = props
            .whereType<Map<String, dynamic>>()
            .map(RetroDosboxConfigProperty.fromJson)
            .toList(growable: false);
      });
      _cache = parsed;
      return parsed;
    } on Object {
      return const {};
    }
  }

  @override
  Future<List<String>> sections() async => (await _load()).keys.toList();

  @override
  Future<List<RetroDosboxConfigProperty>> properties(String section) async =>
      (await _load())[section] ?? const <RetroDosboxConfigProperty>[];

  @override
  Future<bool> set(String section, String property, String value) async {
    final loaded = await _load();
    if (loaded.isEmpty) return false;
    input.configSet(section, property, value);

    // Remember what was asked for. The dump is written once per session, so
    // without this the screen would snap back to the launch-time value the
    // moment it rebuilt and every change would look like it had been
    // rejected.
    final props = loaded[section];
    if (props != null) {
      final i = props.indexWhere((p) => p.name == property);
      if (i >= 0) {
        loaded[section] = List<RetroDosboxConfigProperty>.from(props)
          ..[i] = props[i].copyWith(value: value);
      }
    }
    return true;
  }

  @override
  Future<bool> save() async => false;

  @override
  bool get canSave => false;
}
