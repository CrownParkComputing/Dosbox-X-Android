import 'conf_overrides.dart';
import 'dos_settings.dart';

/// Serialises settings into the dosbox-x.conf the core reads.
///
/// Overrides-only: every option the user has not touched is left to the
/// core's defaults. The era preset writes cycles and memsize - but an
/// explicit override of either wins, because the advanced screen is the
/// senior of the two.
class ConfGenerator {
  const ConfGenerator._();

  static String generate(DosSettings s, [ConfOverrides? overrides]) {
    final ConfOverrides o = overrides ?? ConfOverrides.empty();
    final Map<String, Map<String, String>> merged =
        <String, Map<String, String>>{};

    void put(String section, String key, String value) {
      (merged[section] ??= <String, String>{})[key] = value;
    }

    // Windowed, never fullscreen=true: on Android the SDL window is the whole
    // display already, and the content-scale patches (0005/0006) only live in
    // the windowed path. fullscreen=true takes the desktop path, which clips
    // against 1920x1080 while the surface is content-sized - window_too_small
    // then latches and the renderer drops every frame (the black screen).
    put('sdl', 'fullscreen', 'false');
    put('sdl', 'autolock', 'true');
    // The three keys the Java launcher always wrote and Android cannot run
    // without: surface output (the patched fast path - anything else paints
    // nothing and reads as a black screen), and no core-drawn chrome.
    put('sdl', 'output', 'surface');
    put('sdl', 'showmenu', 'false');
    put('sdl', 'showdetails', 'false');
    // bilinear aspect is what the Android render patch serves; the store
    // launcher always wrote it and the surface path is tuned for it.
    put('render', 'aspect', 'bilinear');
    put('dosbox', 'machine', 'svga_s3');
    put('dosbox', 'memsize', '${s.machine.memsizeMb}');
    put('cpu', 'core', 'normal');
    put('cpu', 'cycles', s.machine.cycles);
    put('sblaster', 'sbtype', s.soundBlaster ? 'sb16' : 'none');
    put('gus', 'gus', '${s.gus}');

    // The advanced screen outranks the preset.
    o.bySection.forEach((String section, Map<String, String> keys) {
      keys.forEach((String key, String value) => put(section, key, value));
    });

    final StringBuffer b = StringBuffer()
      ..writeln('# Written by the launcher. Edits are overwritten on launch.');
    for (final MapEntry<String, Map<String, String>> section
        in merged.entries) {
      b
        ..writeln()
        ..writeln('[${section.key}]');
      for (final MapEntry<String, String> kv in section.value.entries) {
        b.writeln('${kv.key}=${kv.value}');
      }
    }

    b
      ..writeln()
      ..writeln('[autoexec]');
    if (s.mountPath.isNotEmpty) {
      b
        ..writeln('mount c "${s.mountPath}"')
        ..writeln('c:');
    }
    for (final String line in s.autoexec.split('\n')) {
      if (line.trim().isNotEmpty) b.writeln(line.trim());
    }
    return b.toString();
  }
}
