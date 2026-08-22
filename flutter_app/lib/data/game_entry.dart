// What the library holds.
//
// The important difference from the VICE app's MediaEntry: a C64 title is one
// file (a .d64 you attach), whereas a DOS title is usually a FOLDER containing
// an installed game plus any number of disc images, and sometimes instead a
// bootable disk image or a bare CD. That is why this is a small hierarchy of
// kinds rather than a path plus an extension.
import 'package:path/path.dart' as p;

/// How a library entry has to be launched. Each kind produces a materially
/// different dosbox-x.conf (see RetroDosboxConfBuilder), which is why the distinction
/// is modelled rather than inferred at launch time.
enum GameKind {
  /// A folder holding an installed DOS game. Mounted as C:, then a launcher
  /// .exe/.com/.bat inside it is run.
  dosFolder('DOS'),

  /// A CD image (.iso/.cue/.bin) with no installed copy yet. Mounted as a
  /// CD-ROM alongside a writable C:, so the game can be played from disc or
  /// installed.
  discImage('CD'),

  /// A bootable floppy image. Mounted as A: and booted directly. Kept
  /// distinct from a CD image and a hard-disk image because DOSBox-X needs a
  /// different imgmount type and boot drive for each.
  floppyImage('FLOPPY'),

  /// A bootable hard disk image, typically a Windows 9x install. Booted
  /// directly rather than run from a DOS prompt.
  bootImage('BOOT'),

  /// A ZIP (or other archive) that has not been extracted yet. Cannot be
  /// launched directly -- it has to be imported first.
  archive('ZIP');

  /// Short label for the library card's cover slot.
  final String label;
  const GameKind(this.label);
}

/// The emulated hardware generation to target.
///
/// Ported from the Java app's GameMeta presets. These are not cosmetic: DOS
/// games are famously speed-sensitive in both directions. Too fast and 80s
/// titles become unplayable (they used busy loops for timing); too slow and
/// mid-90s titles crawl. `auto` defers to the heuristics in RetroDosboxConfBuilder.
enum CpuPreset {
  /// Let the per-title heuristics decide.
  auto('Automatic', null),

  /// XT/AT class: CGA, slow fixed clock.
  era80s('1980s (XT/AT, CGA)', '3000'),

  /// 386/486 class: VGA, medium clock.
  era90sEarly('Early 1990s (386/486)', '10000'),

  /// Pentium class: SVGA, fast clock.
  era90sLate('Late 1990s (Pentium)', '30000'),

  /// Uncapped -- as fast as the host can manage.
  pentium('Maximum speed', 'max');

  final String label;

  /// The `cycles` value this preset forces, or null for `auto`.
  final String? cycles;

  const CpuPreset(this.label, this.cycles);
}

/// Per-title settings the user can override, persisted separately from the
/// scan results so a rescan never discards them. Mirrors the Java GameMeta.
class GameSettings {
  final CpuPreset preset;

  /// Emulate a 3dfx Voodoo via the software rasterizer. Off by default because
  /// it costs a lot of host CPU and only a handful of titles want it.
  final bool voodoo;

  /// Present the emulated PC joystick. Many DOS games are keyboard-only, and a
  /// few actively misbehave when they detect an idle joystick.
  final bool joystick;

  /// Extra raw dosbox-x.conf text appended verbatim, for the user's own
  /// overrides.
  final String advanced;

  const GameSettings({
    this.preset = CpuPreset.auto,
    this.voodoo = false,
    this.joystick = true,
    this.advanced = '',
  });

  GameSettings copyWith({
    CpuPreset? preset,
    bool? voodoo,
    bool? joystick,
    String? advanced,
  }) {
    return GameSettings(
      preset: preset ?? this.preset,
      voodoo: voodoo ?? this.voodoo,
      joystick: joystick ?? this.joystick,
      advanced: advanced ?? this.advanced,
    );
  }

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        'voodoo': voodoo,
        'joystick': joystick,
        'advanced': advanced,
      };

  factory GameSettings.fromJson(Map<String, dynamic> json) {
    return GameSettings(
      preset: CpuPreset.values.firstWhere(
        (v) => v.name == json['preset'],
        orElse: () => CpuPreset.auto,
      ),
      voodoo: json['voodoo'] as bool? ?? false,
      joystick: json['joystick'] as bool? ?? true,
      advanced: json['advanced'] as String? ?? '',
    );
  }
}

/// One library entry.
class GameEntry {
  /// Folder for [GameKind.dosFolder], file for every other kind.
  final String path;

  final GameKind kind;

  /// Display name. Folder name or filename without extension.
  final String title;

  /// Candidate programs to run, for [GameKind.dosFolder]. Absolute paths.
  /// Empty when the scan found none, in which case the user is dropped at a
  /// DOS prompt rather than being told the game is broken.
  final List<String> launchers;

  /// Disc images found alongside the game, mounted automatically. More than
  /// one forms a swap set.
  final List<String> discs;

  const GameEntry({
    required this.path,
    required this.kind,
    required this.title,
    this.launchers = const <String>[],
    this.discs = const <String>[],
  });

  /// Stable key for persisting per-title settings and save states. Derived
  /// from the title rather than the full path so moving the games folder does
  /// not orphan a user's settings.
  String get slug {
    final lower = title.toLowerCase();
    final buf = StringBuffer();
    for (final ch in lower.codeUnits) {
      final isDigit = ch >= 0x30 && ch <= 0x39;
      final isLower = ch >= 0x61 && ch <= 0x7A;
      buf.writeCharCode(isDigit || isLower ? ch : 0x5F); // '_'
    }
    return buf.toString();
  }

  /// The launcher to use when the user just says "play", or null to drop them
  /// at a prompt.
  ///
  /// Prefers a .bat over an .exe: shipped batch files usually set up the
  /// environment (sound card variables, CD paths) that the bare executable
  /// assumes has already happened. This mirrors the Java findLaunchers, which
  /// collected .bat and .exe into separate lists and preferred the former.
  /// Programs that ship alongside a game and are never the game.
  ///
  /// Shareware titles of the era all carry these: order forms, dealer lists,
  /// catalogues, installers. They sort early alphabetically, so "first
  /// launcher wins" picks them remarkably often -- Commander Keen 1 launches
  /// Apogee's DEALERS.EXE, not KEEN1.EXE.
  static const _notTheGame = {
    'catalog', 'dealers', 'order', 'orderfrm', 'vendor', 'install',
    'setup', 'readme', 'read', 'help', 'uninst', 'uninstal', 'config',
  };

  static bool _isLikelyGame(String path) =>
      !_notTheGame.contains(p.basenameWithoutExtension(path).toLowerCase());

  /// The program to run, or null if this entry is not a folder of programs.
  ///
  /// Prefers a .bat over an .exe: shipped batch files usually set up the
  /// environment (sound card variables, CD paths) that the bare executable
  /// assumes has already happened. This mirrors the Java findLaunchers, which
  /// collected .bat and .exe into separate lists and preferred the former.
  ///
  /// Within each group, an executable named after the folder wins (KEEN1.EXE
  /// in CKeen1/), then anything that is not obviously an installer or order
  /// form, and only then the first entry. The fallbacks matter: a title whose
  /// every candidate looks like packaging still has to launch something rather
  /// than nothing.
  String? get preferredLauncher {
    if (launchers.isEmpty) return null;

    final bats = launchers
        .where((l) => p.extension(l).toLowerCase() == '.bat')
        .toList();
    final group = bats.isNotEmpty ? bats : launchers;

    final folder = p.basename(path).toLowerCase();
    for (final l in group) {
      final stem = p.basenameWithoutExtension(l).toLowerCase();
      // Either direction: KEEN1.EXE in CKeen1/, and DOOM.EXE in doom/.
      if (folder.contains(stem) || stem.contains(folder)) return l;
    }

    for (final l in group) {
      if (_isLikelyGame(l)) return l;
    }
    return group.first;
  }

  /// Whether tapping this entry launches a session.
  ///
  /// Archives used to be unlaunchable (the user had to import first), but a
  /// 3,000-title zip collection is the dominant case for this app and
  /// requiring every title to be imported just to play it is a wall. They
  /// are now launched in place via ZipRunner, which extracts the archive
  /// into a per-title cache directory and overlays the user's save files.
  bool get isLaunchable => true;

  /// Short label for the card cover.
  String get kindLabel => kind.label;
}
