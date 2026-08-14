/// What a DOS setup is, before it becomes a conf file.
///
/// Mirrors EmulatorSettings in the Amiga launcher: a small, testable model
/// the wizard edits and the generator serialises. Presets first - most
/// people want "a 486 that runs my game", not forty dosbox.conf keys.
class DosMachine {
  const DosMachine(this.id, this.displayName, this.cycles, this.memsizeMb);

  final String id;
  final String displayName;

  /// dosbox-x `cycles=` value. Fixed counts beat `auto` for era-accuracy:
  /// auto on a phone means "as fast as the phone", which breaks timing-
  /// sensitive games exactly the way it did on fast Pentiums.
  final String cycles;
  final int memsizeMb;

  static const DosMachine xt = DosMachine('xt', 'PC/XT (8088)', '315', 1);
  static const DosMachine at286 = DosMachine('286', '286 AT', '1500', 2);
  static const DosMachine dx386 = DosMachine('386', '386DX', '7800', 4);
  static const DosMachine dx486 = DosMachine('486', '486DX2-66', '26800', 8);
  static const DosMachine pentium =
      DosMachine('pentium', 'Pentium 90', '77000', 16);
  static const DosMachine max = DosMachine('max', 'As fast as possible', 'max', 64);

  static const List<DosMachine> all = <DosMachine>[
    xt, at286, dx386, dx486, pentium, max,
  ];

  static DosMachine byId(String? id) =>
      all.firstWhere((DosMachine m) => m.id == id, orElse: () => dx486);
}

class DosSettings {
  const DosSettings({
    this.machine = DosMachine.dx486,
    this.soundBlaster = true,
    this.gus = false,
    this.mountPath = '',
    this.autoexec = '',
  });

  final DosMachine machine;
  final bool soundBlaster;
  final bool gus;

  /// Host folder mounted as C:.
  final String mountPath;

  /// Lines run after mount - typically cd into the game and start it.
  final String autoexec;

  DosSettings copyWith({
    DosMachine? machine,
    bool? soundBlaster,
    bool? gus,
    String? mountPath,
    String? autoexec,
  }) =>
      DosSettings(
        machine: machine ?? this.machine,
        soundBlaster: soundBlaster ?? this.soundBlaster,
        gus: gus ?? this.gus,
        mountPath: mountPath ?? this.mountPath,
        autoexec: autoexec ?? this.autoexec,
      );
}
