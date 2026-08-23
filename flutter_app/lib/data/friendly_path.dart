import 'dart:io';

import 'package:path/path.dart' as p;

/// Renders a path the way the user can actually act on it.
///
/// iOS hands the app a container path -- on device
///   `/var/mobile/Containers/Data/Application/<UUID>/Documents/...`
/// and on a simulator something longer still, rooted in whoever's home
/// directory built it. None of that is reachable or meaningful to a user: what
/// they see in the Files app is "On My iPhone > Retro-DosBox > ...".
///
/// Printing the raw path is wrong twice over. It tells the user to look
/// somewhere that does not exist for them, and it puts the build machine's
/// directory layout -- account name included -- into every screenshot of the
/// screen, which is how it reached an App Store listing.
///
/// [documentsPath] is the app's documents directory. Anything inside it is
/// shown relative to the Files-app entry; anything outside is returned
/// unchanged, because that is a genuine location and not ours to rewrite.
String friendlyPath(
  String absolute,
  String documentsPath, {
  String filesAppName = 'Retro-DosBox',
  String? deviceName,
}) {
  if (absolute.isEmpty) return absolute;
  if (documentsPath.isEmpty) return absolute;
  if (!p.isWithin(documentsPath, absolute)) return absolute;

  final where = deviceName ?? (Platform.isIOS ? 'On My iPhone / iPad' : 'Files');
  final parts = p.split(p.relative(absolute, from: documentsPath));
  return <String>[where, filesAppName, ...parts].join(' › ');
}
