// Generates the dosbox-x.conf that launches a title.
//
// This file is a direct port of the Java app's config generation
// (GameLauncherActivity.buildConf / mountLines / cyclesFor / machineFor /
// mixerFor, and GameMeta's presets). It is worth being explicit about why it
// looks the way it does: almost every constant and special case below is a
// compatibility workaround discovered by running real games and watching them
// break. They are not arbitrary defaults and should not be "cleaned up"
// without a specific title to test against. Each one carries the reason it
// exists.
//
// The conf file is the ONLY channel by which a title is launched: mounts,
// machine type, cycles and the [autoexec] that runs the program all live in
// it, which is why the bridge's start() takes nothing but a path to one.
import 'dart:io';
import 'package:path/path.dart' as p;

import '../data/game_entry.dart';
import 'disk_image.dart';
import 'zip_runner.dart';

class RetroDosboxConfBuilder {
  RetroDosboxConfBuilder._();

  /// Builds the full conf text for [entry].
  ///
  /// [launcher] overrides [GameEntry.preferredLauncher] when the user picked a
  /// specific program (an installer, a setup utility, an alternate exe).
  /// Passing null for both drops the user at a DOS prompt with a directory
  /// listing, which is the right outcome when we genuinely cannot tell what to
  /// run -- better than guessing wrong and appearing to hang.
  ///
  /// [archiveSetup] is required when [entry] is an archive: the archive has
  /// to be extracted into a cache directory before dosbox-x can mount it,
  /// and that step happens upstream of conf construction. See ZipRunner.
  static String build({
    required GameEntry entry,
    required GameSettings settings,
    String? launcher,
    String? globalAdvanced,
    ArchiveRunSetup? archiveSetup,

    /// Where per-title capture directories live. The save slots hang off
    /// this, so it has to be somewhere writable that survives the session.
    required String captureRoot,

    /// True when the core will run in its own process with an SDL window,
    /// false when it runs in-process and publishes frames back to Flutter.
    required bool windowed,
  }) {
    final program =
        launcher ??
        (entry.kind == GameKind.archive
            ? archiveSetup?.launcher
            : entry.preferredLauncher);
    final programName = program == null ? null : p.basename(program);

    /// The discs actually in the machine: the one the user chose first, then
    /// whatever was found beside the title. Chosen first because it is the
    /// deliberate one, and for a Windows guest the first disc gets the IDE
    /// slot the guest's own driver looks at.
    final discs = <String>[
      if (settings.cdImage.trim().isNotEmpty) settings.cdImage.trim(),
      for (final d in entry.discs)
        if (d != settings.cdImage.trim()) d,
    ];

    final autoexec = switch (entry.kind) {
      GameKind.dosFolder => _dosFolderAutoexec(entry, discs, program),
      GameKind.discImage => _discImageAutoexec(entry),
      GameKind.floppyImage => _floppyImageAutoexec(entry),
      GameKind.bootImage => _bootImageAutoexec(entry, discs),
      GameKind.archive => _archiveAutoexec(archiveSetup, program),
    };

    return _assemble(
      autoexec: autoexec,
      machine: _machineFor(entry, settings, programName),
      cpuCore: _cpuCoreFor(settings),
      cycles: _cyclesFor(entry, settings, programName),
      mixer: _mixerFor(programName),
      voodoo: settings.voodoo || _defaultVoodoo(programName),
      joystick: settings.joystick,
      capturesDir: p.join(captureRoot, entry.slug),
      windowed: windowed,
      advanced: [
        settings.advanced,
        globalAdvanced ?? '',
      ].where((s) => s.trim().isNotEmpty).join('\n'),
    );
  }

  // --- Sections ------------------------------------------------------------

  static String _assemble({
    required List<String> autoexec,
    required String machine,
    required String cpuCore,
    required String cycles,
    required String mixer,
    required bool voodoo,
    required bool joystick,
    required String advanced,
    required String capturesDir,
    required bool windowed,
  }) {
    final sb = StringBuffer();

    // output=gamelink is what the bridge hooks: it is DOSBox-X's offscreen
    // backend, rendering to a plain 32bpp buffer instead of a window. The
    // bridge does NOT select this itself -- the conf is the only channel -- so
    // getting it wrong is silent: the engine boots and renders perfectly into a
    // window surface the bridge cannot see, and the app shows a black screen.
    //
    // `gamelink master` is not optional either. Without it
    // OUTPUT_GAMELINK_Select() refuses and falls back to output=surface with
    // only a log line, producing exactly the same silent black screen.
    //
    // The menu bar is hidden because this front end draws its own UI around the
    // picture -- a DOSBox menu bar inside the Flutter frame would be redundant
    // and would eat a row of pixels.
    sb.writeln('[sdl]');
    // Offscreen when the core runs inside this process, a real window when it
    // runs in its own. The bridge hooks OUTPUT_GAMELINK_Transfer to publish
    // frames back to Flutter; SDLActivity instead gives DOSBox-X a SurfaceView
    // to draw straight into, and gamelink there would render into a buffer
    // nobody reads - a black screen from an engine that is running perfectly.
    sb.writeln(windowed ? 'output=surface' : 'output=gamelink');
    sb.writeln('gamelink master=true');
    sb.writeln('showmenu=false');
    sb.writeln('showdetails=false');
    sb.writeln();

    // Aspect correction is left OFF here on purpose. DOSBox-X's own aspect
    // handling would bake the correction into the framebuffer, and this front
    // end instead applies it at draw time from the ratio the core reports
    // (see FramebufferView / dosbox_core_get_pixel_aspect_x1000). Doing it in
    // both places would stretch the picture twice.
    sb.writeln('[render]');
    sb.writeln('aspect=false');
    sb.writeln();

    // memsize stays at 32MB, below 64: DOS/4GW 1.97 breaks outright when it
    // sees 64MB or more, failing with "Unable to find <game>.exe in ''".
    // IndyCar Racing 2 is the canonical victim.
    sb.writeln('[dosbox]');
    sb.writeln('machine=$machine');
    sb.writeln('memsize=32');
    // Do not flock() the disk image.
    //
    // fopen_lock() opens the image "rb+" and then takes an exclusive flock;
    // if the lock fails it CLOSES THE FILE and reports failure, so a disk
    // image that is present, readable and byte-perfect comes back as "Could
    // not open the specified VHD file". FUSE-backed storage does not support
    // flock, which is exactly what an SD card is on Android -- so moving a
    // library to the card made every bootable image unopenable while the same
    // file worked from internal storage.
    //
    // What the lock buys is a guard against mounting one image read/write in
    // two places at once. This app launches one machine at a time from its
    // own folder, so there is no second mounter to guard against.
    sb.writeln('locking disk image mount=false');
    // A capture directory per title, because the save slots hang off it.
    //
    // DOSBox-X writes a save state to <capture>/../save/<slot>.sav, so with
    // one shared capture directory every title shares slot 0 and starting a
    // second game silently overwrites the first one's snapshot. Per-title
    // means slot 0 is that title's slot, and switching games can snapshot
    // what it leaves behind instead of destroying it.
    sb.writeln('captures=${_quote(capturesDir)}');
    sb.writeln();

    sb.writeln('[cpu]');
    sb.writeln('core=$cpuCore');
    // pentium_mmx for a Windows 9x guest: Windows 98 SE and a good deal of
    // late-90s software probe CPUID for MMX and take a different (and in
    // places the only tested) code path when they find it.
    sb.writeln('cputype=pentium');
    sb.writeln('cycles=$cycles');
    sb.writeln();

    sb.write(mixer);

    // sbpro2 rather than sb16: sbpro2 uses 8-bit DMA, which plays digital
    // sound effects reliably, whereas sb16's 16-bit DMA frequently goes
    // silent under DOSBox for a lot of DOS titles.
    sb.writeln('[sblaster]');
    sb.writeln('sbtype=sbpro2');
    sb.writeln('sbbase=220');
    sb.writeln('irq=7');
    sb.writeln('dma=1');
    sb.writeln('oplmode=auto');
    sb.writeln();

    // 3dfx via the CPU rasterizer. Off unless the title is tagged for it,
    // because the software rasterizer is expensive on mobile hardware.
    sb.writeln('[voodoo]');
    sb.writeln('voodoo_card=${voodoo ? 'software' : 'false'}');
    sb.writeln();

    if (joystick) {
      sb.writeln('[joystick]');
      sb.writeln('joysticktype=2axis');
      sb.writeln('timed=false');
      sb.writeln('joy1deadzone1=0.35');
      sb.writeln('joy1deadzone2=0.35');
      sb.writeln();
    } else {
      // Explicitly none rather than omitted: a few titles probe for a
      // joystick, find a permanently centred one, and either wait for it to
      // be calibrated or drift.
      sb.writeln('[joystick]');
      sb.writeln('joysticktype=none');
      sb.writeln();
    }

    if (advanced.trim().isNotEmpty) {
      sb.writeln('# Advanced settings');
      sb.writeln(advanced.trim());
      sb.writeln();
    }

    sb.writeln('[autoexec]');
    sb.writeln('@echo off');
    // A number of 1989-1992 games only enable digital audio when the BLASTER
    // environment is present, even though DOSBox has configured the card.
    // Keep it aligned with the sbpro2 settings above (A220/I7/D1, high DMA 5,
    // MPU-401 at 330, Sound Blaster-compatible type 6).
    sb.writeln('set BLASTER=A220 I7 D1 H5 P330 T6');
    for (final line in autoexec) {
      sb.writeln(line);
    }
    return sb.toString();
  }

  /// Bigger audio buffers for 3dfx titles: triangle-heavy frames take long
  /// enough that a small buffer underruns and the sound audibly breaks up.
  static String _mixerFor(String? programName) {
    final blockSize = _isVoodooProgram(programName) ? 2048 : 1024;
    final prebuffer = _isVoodooProgram(programName) ? 80 : 25;
    return '[mixer]\n'
        'nosound=false\n'
        'rate=44100\n'
        'blocksize=$blockSize\n'
        'prebuffer=$prebuffer\n\n';
  }

  // --- autoexec construction ----------------------------------------------

  /// Mount lines for an installed DOS game in a folder.
  static List<String> _dosFolderAutoexec(
    GameEntry entry,
    List<String> discs,
    String? program,
  ) {
    final lines = <String>[];

    // IndyCar Racing 2 asks DOS/4GW for its own path (DOS4G_GET_APPPATH) and
    // dies with "Unable to find IndyCar.exe in ''" when it sits at the C:
    // root. Mounting the PARENT and running from a subdirectory gives it a
    // non-empty path to report. Matched on the folder name because there is
    // no other reliable signal available at scan time.
    final subdirMount = p.basename(entry.path).toLowerCase().contains('indy');
    final root = subdirMount ? p.dirname(entry.path) : entry.path;

    lines.add('mount c ${_quote(root)}');
    lines.addAll(_discMountLines(discs));
    lines.add('c:');

    if (program != null) {
      // cd into the program's own directory first: DOS games routinely open
      // their data files by relative path and fail from anywhere else.
      final rel = p.relative(program, from: root);
      final dir = p.dirname(rel);
      if (dir != '.' && dir.isNotEmpty) {
        lines.add('cd ${_quote(dir.replaceAll('/', r'\'))}');
      }
      lines.add(p.basename(program));
    } else {
      if (subdirMount) {
        lines.add('cd ${_quote(p.basename(entry.path))}');
      }
      lines.addAll(_promptFallback());
    }
    return lines;
  }

  /// A CD image with a writable C: alongside, so the game can be installed or
  /// played straight from disc.
  static List<String> _discImageAutoexec(GameEntry entry) {
    final lines = <String>[];
    // A persistent writable C: living next to the image. Games that insist on
    // installing, or that write saves and config, need somewhere real to put
    // them -- and it has to survive between sessions, which is why it is a
    // sibling directory rather than a temporary one.
    final cDir = p.join(p.dirname(entry.path), '.c', entry.slug);
    lines.add('mount c ${_quote(cDir)}');
    lines.addAll(_discMountLines([entry.path, ...entry.discs]));
    lines.add('c:');
    lines.addAll(_promptFallback(cdHint: true));
    return lines;
  }

  static List<String> _bootImageAutoexec(
    GameEntry entry,
    List<String> discs,
  ) {
    // boot -l c hands the machine to the image's own boot sector, so no
    // mounting of C: and no autoexec beyond this line: everything after the
    // boot is the guest OS's business.
    //
    // The drive is named by BIOS NUMBER, not by letter. `-fs none` attaches a
    // raw BIOS disk rather than mounting a filesystem, and imgmount then
    // rejects a letter outright -- "Must specify drive number (0 to 5)" --
    // leaving the user at a DOSBox prompt with "BOOT: Failed to open disk
    // image" underneath it. 2 is hda, the first hard disk, which `boot -l c`
    // below then names by the letter the guest will see. The floppy path
    // already had this right; this one did not.
    final lines = <String>[
      'imgmount 2 ${_quote(entry.path)} -t hdd -fs none',
    ];
    var letter = 'd'.codeUnitAt(0);
    for (final disc in discs) {
      lines.add(
        'imgmount ${String.fromCharCode(letter)} ${_quote(disc)} -t iso',
      );
      if (letter < 'z'.codeUnitAt(0)) letter++;
    }
    lines.add('boot -l c');
    return lines;
  }

  static List<String> _floppyImageAutoexec(GameEntry entry) => <String>[
    // With -fs none DOSBox-X attaches a raw BIOS disk, so imgmount expects
    // BIOS slot 0 (first floppy), not the DOS drive letter A. `boot -l a`
    // below still names the boot drive by letter.
    'imgmount 0 ${_quote(entry.path)} -t floppy -fs none',
    'boot -l a',
  ];

  /// Mounts a previously-extracted archive as C:, with a writable overlay
  /// for save data. The overlay is a real directory mounted as D: so dosbox
  /// can write files back to it during play; the ZipRunner then copies
  /// changed files into the persistent save slot after the session ends.
  ///
  /// The extracted tree at [ArchiveRunSetup.cacheRoot] is read-only. The
  /// writable D: lives at [ArchiveRunSetup.saveRoot]; on next launch the
  /// contents of saveRoot are copied on top of cacheRoot so the user sees
  /// the same files they saved.
  static List<String> _archiveAutoexec(
    ArchiveRunSetup? setup,
    String? program,
  ) {
    final lines = <String>[];
    if (setup == null) {
      return <String>['echo This archive could not be extracted.'];
    }
    // DOS/4GW-based games such as NASCAR Racing inspect their application
    // path and fail with "Unable to find ... in ''" when started at C:\\ root.
    // Mount the cache parent and enter the title directory so DOS reports a
    // non-empty executable path while preserving the extracted tree layout.
    final cacheParent = p.dirname(setup.cacheRoot);
    final cacheName = p.basename(setup.cacheRoot);
    lines.add('mount c ${_quote(cacheParent)}');
    lines.add('mount d ${_quote(setup.saveRoot)}');
    lines.add('c:');
    // DOSBox-X's Android directory backend exposes long host directory names
    // through their DOS 8.3 aliases. Use that alias for the cache slug so CD
    // works even when long-filename support is unavailable.
    final dosCacheName = cacheName.length > 8
        ? '${cacheName.substring(0, 6).toUpperCase()}~1'
        : cacheName;
    lines.add('cd $dosCacheName');
    if (program != null) {
      // Mirror _dosFolderAutoexec: cd into the program's directory so
      // relative data-file opens work.
      final rel = p.relative(program, from: setup.cacheRoot);
      final dir = p.dirname(rel);
      if (dir != '.' && dir.isNotEmpty) {
        lines.add('cd ${_quote(dir.replaceAll('/', r'\'))}');
      }
      lines.add(p.basename(program));
    } else {
      lines.addAll(_promptFallback());
    }
    return lines;
  }

  /// imgmount lines for a set of disc/disk images, assigning drive letters
  /// from D: upward.
  ///
  /// Images are grouped by type before mounting because the -t flag has to
  /// match the set, and because several images of the same type mounted on one
  /// letter form a swap set the user can cycle through -- which is how
  /// multi-disc games are meant to work.
  static List<String> _discMountLines(List<String> discs) {
    if (discs.isEmpty) return const <String>[];

    final isos = <String>[];
    final rawTracks = <String>[];
    final hdds = <String>[];
    for (final disc in discs) {
      final ext = p.extension(disc).toLowerCase();
      if (ext == '.whd' || ext == '.hdf' || ext == '.lha') {
        hdds.add(disc);
      } else if (ext == '.cue' || ext == '.bin') {
        // .bin is a raw 2352-byte-sector track and cannot be mounted alone --
        // it needs a .cue describing it. The Java app generated one on the
        // fly; that generation is part of the media-import port, so here we
        // only route the file to the right group.
        rawTracks.add(disc);
      } else {
        isos.add(disc);
      }
    }

    final lines = <String>[];
    var letter = 'd'.codeUnitAt(0);

    // Secondary hard disks first, so CD letters stay predictable.
    for (final hdd in hdds) {
      lines.add(
        'imgmount ${String.fromCharCode(letter)} '
        '${_quote(hdd)} -t hdd -fs none',
      );
      if (letter < 'z'.codeUnitAt(0)) letter++;
    }
    for (final group in [isos, rawTracks]) {
      if (group.isEmpty) continue;
      final paths = group.map(_quote).join(' ');
      lines.add('imgmount ${String.fromCharCode(letter)} $paths -t iso');
      if (letter < 'z'.codeUnitAt(0)) letter++;
    }
    return lines;
  }

  /// What to show when there is no program to run: a directory listing and an
  /// instruction, rather than a bare prompt that looks like a failure.
  static List<String> _promptFallback({bool cdHint = false}) {
    return <String>[
      'cls',
      'dir /w',
      'echo.',
      if (cdHint)
        'echo Type D: then DIR to browse the disc, or run the installer.'
      else
        'echo Type the EXE or BAT name to run the game.',
    ];
  }

  // --- Per-title heuristics ------------------------------------------------

  /// `normal` for 80s titles, `dynamic` otherwise.
  ///
  /// The dynamic core is much faster but recompiles blocks, which some very
  /// old software defeats by writing to its own code. The 80s preset does not
  /// need the speed anyway.
  static String _cpuCoreFor(GameSettings settings) {
    // Never the dynamic core on iOS. It recompiles x86 blocks into native
    // code at runtime, and Apple does not permit an app to make memory both
    // writable and executable -- the same wall that keeps every App Store
    // emulator interpreter-only. Asking for it there is not slow, it is a
    // core that cannot honour the request. The interpreter is the honest
    // ceiling on that platform.
    if (Platform.isIOS) return 'normal';

    // The dynamic core is much faster but recompiles blocks, which some very
    // old software defeats by writing to its own code. The 80s preset does not
    // need the speed anyway.
    if (settings.preset == CpuPreset.era80s) return 'normal';

    return 'dynamic';
  }

  /// The `cycles` value, which is the single most important compatibility knob
  /// DOSBox has.
  static String _cyclesFor(
    GameEntry entry,
    GameSettings settings,
    String? programName,
  ) {
    // An explicit user preset always wins over the heuristics.
    final presetCycles = settings.preset.cycles;
    if (presetCycles != null) return presetCycles;

    final prog = (programName ?? '').toLowerCase();
    final title = entry.title.toLowerCase();

    // Screamer's SETUP.EXE is the canonical speed-sensitive installer: it
    // crashes outright at cycles=max, and needs a notably lower fixed clock
    // than other setup programs to get through.
    if (title.contains('screamer') && _isSetupProgram(programName)) {
      return 'fixed 12000';
    }
    // Setup and install utilities in general are timing-sensitive -- they
    // probe hardware with delay loops -- so they get a modest fixed clock
    // rather than the uncapped speed a game wants.
    if (_isSetupProgram(programName)) return 'fixed 20000';

    // 3dfx titles need a lot of headroom for the software rasterizer, and a
    // fixed clock keeps their frame pacing stable.
    if (_isVoodooProgram(programName)) return 'fixed 100000';

    // Screamer proper wants a high fixed clock for sane game speed.
    if (title.contains('screamer')) return 'fixed 150000';

    // Keep the explicit check on the leading name that the Java version had:
    // s2_3dfx is Screamer 2's 3dfx executable and is matched before the
    // generic contains() test above would catch it anyway, so this is
    // deliberately redundant rather than load-bearing.
    if (prog.startsWith('s2_3dfx')) return 'fixed 100000';

    return 'auto';
  }

  /// The emulated graphics hardware.
  static String _machineFor(
    GameEntry entry,
    GameSettings settings,
    String? programName,
  ) {
    if (settings.preset == CpuPreset.era80s) return 'cga';

    // Screamer's setup program specifically needs a VESA mode without a
    // linear framebuffer; svga_s3 makes it misdetect and fail.
    if (entry.title.toLowerCase().contains('screamer') &&
        _isSetupProgram(programName)) {
      return 'vesa_nolfb';
    }

    // svga_s3 otherwise: it exposes the widest set of high-resolution SVGA
    // modes, so games pick their best available option.
    return 'svga_s3';
  }

  /// Whether a program name looks like a hardware setup or install utility.
  ///
  /// The bare `set` prefix is deliberately broad -- it catches SETSOUND,
  /// SETSND, SETUP and friends. The cost of a false positive is only a lower
  /// CPU clock for one program, whereas a false negative is a crash, so this
  /// errs toward matching.
  static bool _isSetupProgram(String? programName) {
    final p0 = (programName ?? '').toLowerCase();
    return p0.startsWith('setup') ||
        p0.startsWith('install') ||
        p0.startsWith('dosinst') ||
        p0.startsWith('setsound') ||
        p0.startsWith('setsnd') ||
        p0.startsWith('set') ||
        p0.startsWith('config');
  }

  static bool _isVoodooProgram(String? programName) {
    final p0 = (programName ?? '').toLowerCase();
    return p0.contains('3dfx') ||
        p0.contains('voodoo') ||
        p0.startsWith('whip3dfx');
  }

  /// Whether to switch the Voodoo on without the user asking, based on the
  /// executable name announcing itself as a 3dfx build.
  static bool _defaultVoodoo(String? programName) =>
      _isVoodooProgram(programName);

  /// The smallest image that looks like an installed operating system
  /// rather than a DOS boot disk.
  ///
  /// A period DOS boot disk is tens of megabytes; the smallest usable
  /// Windows 98 SE install is several hundred. 300MB sits in the empty space
  /// between the two.
  static const int _installedOsMinBytes = 300 * 1024 * 1024;

  /// Whether this image looks like an installed Windows rather than DOS.
  ///
  /// Nothing in the generated conf depends on this -- the machine is the same
  /// either way. It exists so the library can SAY so, because a Windows image
  /// that boots to a hang is a far worse answer than one the app declines up
  /// front and explains. See WhyNotWindowsScreen.
  static bool looksLikeInstalledWindows(GameEntry entry) {
    if (entry.kind != GameKind.bootImage) return false;
    return DiskImage.virtualSize(entry.path) >= _installedOsMinBytes;
  }

  /// Quotes a path for the DOS command line.
  ///
  /// Host paths reach the guest verbatim through mount/imgmount, and on
  /// Android they contain spaces as a matter of course
  /// (/storage/emulated/0/...), so quoting is not optional. Embedded double
  /// quotes are dropped rather than escaped: DOS has no escape syntax for
  /// them, so a filename containing one cannot be expressed at all, and
  /// silently stripping it produces a wrong path instead of a broken command.
  static String _quote(String path) => '"${path.replaceAll('"', '')}"';
}
