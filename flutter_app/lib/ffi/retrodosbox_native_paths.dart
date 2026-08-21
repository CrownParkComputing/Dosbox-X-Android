// Locating the native core library and DOSBox-X's resource tree, per platform.
//
//   - Linux (dev): the .so is found by walking up to the repo root and
//     looking in native/dosbox_core/linux/build/. Only works from a checkout;
//     packaging should instead ship it next to the executable and derive the
//     path from Platform.resolvedExecutable.
//   - Android: the .so ships in jniLibs/<abi>/ and is loaded by bare name, so
//     the path getter returns null on purpose.
//   - iOS: the bridge is linked into the app binary, so there is nothing to
//     open (DynamicLibrary.process()) and again no path.
import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class RetroDosboxNativePaths {
  RetroDosboxNativePaths._();

  /// Marker written after a successful resource extraction, so subsequent
  /// launches skip re-copying the whole asset subtree.
  ///
  /// Unlike a plain existence check this stores the sorted asset manifest it
  /// was written for: the bundled resource set grows between releases, and an
  /// already-installed app would otherwise skip extraction forever and never
  /// see new files.
  static const String _resourceMarkerName = '.extracted';

  static const String _resourceAssetPrefix = 'assets/dosbox/';

  /// Extracts assets/dosbox/ into a real directory under the app's support
  /// dir and returns it.
  ///
  /// This has to happen because DOSBox-X opens its resources (fonts,
  /// translations, glshaders, the conf template) with plain fopen by path --
  /// an asset bundle handle is not something the native core can use. Safe to
  /// call every launch.
  static Future<String> extractResourceDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final root = p.join(supportDir.path, 'dosbox');
    final marker = File(p.join(root, _resourceMarkerName));

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((path) => path.startsWith(_resourceAssetPrefix))
        .toList()
      ..sort();
    final expected = assets.join('\n');

    if (marker.existsSync() && marker.readAsStringSync() == expected) {
      return root;
    }

    for (final assetPath in assets) {
      final relative = assetPath.substring(_resourceAssetPrefix.length);
      if (relative.isEmpty) continue;
      final outFile = File(p.join(root, relative));
      await outFile.parent.create(recursive: true);
      final bytes = await rootBundle.load(assetPath);
      await outFile.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
    }

    await marker.create(recursive: true);
    await marker.writeAsString(expected, flush: true);
    return root;
  }

  /// Walks up from the working directory (and from the script's own
  /// directory, for `flutter run`'s working-directory quirks) looking for a
  /// DosboxMultiplatform checkout root.
  static Directory? _findRepoRoot() {
    final candidates = <Directory>[
      Directory.current,
      Directory(p.dirname(Platform.script.toFilePath())),
    ];
    for (final start in candidates) {
      Directory dir = start;
      for (int i = 0; i < 8; i++) {
        if (Directory(p.join(dir.path, 'native', 'dosbox_core')).existsSync()) {
          return dir;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }

  /// Absolute path to the core library, or null to fall back to bare-name
  /// loading (Android, where the OS loader resolves the .so from jniLibs).
  static String? get coreLibraryPath {
    if (Platform.isAndroid || Platform.isMacOS) return null;
    if (Platform.isIOS) return _iosFrameworkLibrary('libdosboxcore');
    final root = _findRepoRoot();
    if (root == null) return null;
    final path = p.join(root.path, 'native', 'dosbox_core', 'linux', 'build',
        'libdosboxcore.so');
    return File(path).existsSync() ? path : null;
  }

  /// Absolute path to a dylib shipped inside the iOS app bundle's Frameworks
  /// directory, which sits next to the executable (Runner.app/Runner and
  /// Runner.app/Frameworks/).
  ///
  /// Loaded by explicit path rather than through DynamicLibrary.process: the
  /// dylib is bundled, not linked into the Runner binary, so its symbols are
  /// not in the global namespace until something dlopens it -- and nothing
  /// else references it, so nothing else will.
  ///
  /// It ships as a .framework rather than a loose dylib because iOS validates
  /// every nested Mach-O in Frameworks/ as a code bundle and rejects the
  /// install otherwise (ApplicationVerificationFailed) -- the same trap
  /// tools/fix-ipa-native-assets.sh exists for.
  static String? _iosFrameworkLibrary(String name) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final path = p.join(exeDir, 'Frameworks', '$name.framework', name);
    return File(path).existsSync() ? path : null;
  }

  /// Resource dir resolver that works on every target: Android and iOS
  /// extract bundled assets to real files, Linux prefers the repo's own
  /// resource tree when running from a checkout.
  static Future<String> resolveResourceDir() async {
    if (Platform.isLinux) {
      final root = _findRepoRoot();
      if (root != null) {
        final devDir =
            p.join(root.path, 'native', 'dosbox_core', 'resources');
        if (Directory(devDir).existsSync()) return devDir;
      }
    }
    return extractResourceDir();
  }

  /// Where generated dosbox-x.conf files are written. One per launch rather
  /// than one shared file, so a crashed session cannot leave a config behind
  /// that silently changes the next launch.
  static Future<Directory> confDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'conf'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Where per-title capture directories live.
  ///
  /// The save slots hang off this: DOSBox-X writes a state to
  /// `<capture>/../save/<slot>.sav`, so a capture directory per title is what
  /// gives each title its own slot 0. With one shared directory, starting a
  /// second game overwrites the first one's snapshot.
  ///
  /// Support rather than cache: a snapshot the user can come back to must not
  /// be something the system deletes when it wants space.
  static Future<Directory> captureRoot() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'captures'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }
}
