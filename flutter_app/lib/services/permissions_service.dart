// Shared-storage permission handling.
//
// There is none any more, and this file exists to say so in one place rather
// than leave every caller to work it out.
//
// The app used to ask for MANAGE_EXTERNAL_STORAGE ("All files access"): a DOS
// collection is folders of .exe/.com/.bat plus .iso/.img/.zip, none of which
// are media types, so READ_MEDIA_* never covered them. Play treats that
// permission as sensitive - undeclared it blocks the release, declared it
// means a review aimed at file managers, backup and antivirus apps - and this
// app is replacing a published one.
//
// dosbox-x mounts a directory, so the games live in the app's own external
// folder, which needs no permission and is reachable over USB. A collection
// elsewhere is copied in through the system folder picker. Nothing needs
// granting, so isRelevant is false and the screens that offered a trip to
// Settings stop offering it: that toggle would now grant a permission this
// app does not declare, which does nothing at all.

class PermissionsService {
  PermissionsService._();

  /// Whether this platform needs (and can be granted) shared-storage access
  /// at all. Linux has ordinary filesystem access; iOS imports files into
  /// the sandbox instead.
  static bool get isRelevant => false;

  /// True if the app can currently read arbitrary files out of shared
  /// storage. Always true where the concept doesn't apply.
  static Future<bool> hasStorageAccess() async => true;

  /// Asks for shared-storage access. On Android 11+ this opens the system
  /// "All files access" settings page for this app; the returned value is
  /// the state as of when the call returns, so callers should re-check
  /// after the user comes back.
  /// Nothing to request: the host no longer implements this.
  static Future<bool> requestStorageAccess() async => true;
}
