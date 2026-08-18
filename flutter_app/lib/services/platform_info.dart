import 'dart:io';

/// The platform this build is actually running on.
///
/// The app is multiplatform, but any given copy of it is running on exactly
/// one OS, and saying which is more useful to the person holding it than
/// repeating "multiplatform" back at them. Used by the About tab's
/// "Running on:" line.
String platformName() {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  return 'this platform';
}
