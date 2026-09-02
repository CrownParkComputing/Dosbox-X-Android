# Release identity

The store identities and signing arrangements carried over from the Flutter
application. They are recorded here because they are not derivable from the
code, and getting one wrong is not a build error — it is a rejected upload, or
worse, a second listing that strands every existing user on the old build.

## Android

| | |
|---|---|
| Application id | `com.dosboxx.app` |
| Kotlin namespace | `com.crownparkcomputing.retrodos` |
| Display name | Retro-DOS |
| minSdk / targetSdk / compileSdk | 28 / 36 / 36 |
| NDK | 28.2.13676358 |
| ABIs | `arm64-v8a` |

**The application id is not the package the code lives in, and that is
deliberate.** `com.dosboxx.app` is the identity of the existing Play listing —
originally a Java app, then the Flutter one this replaces. Keeping it is what
makes each release an in-place upgrade: existing users receive it as an update,
reviews and install counts carry over, and the registered upload key keeps
working. Publishing under `com.crownparkcomputing.retrodos` would create a
separate listing with no path forward for anyone already on the old app.

`namespace` and `applicationId` are independent concepts in AGP; the merged
manifest fully qualifies the activity as
`com.crownparkcomputing.retrodos.MainActivity`, so the two never collide.

### Version codes

Play never accepts a version code at or below one already published. The
listing has codes from both predecessors, so `DOSBOX_VERSION_CODE_BASE` in
`android/app/build.gradle.kts` keeps this line clear of them rather than
colliding with it. Raise the offset, never lower the base.

### Signing

The upload keystore is resolved, in order:

1. `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
   `ANDROID_KEY_PASSWORD` — used by CI.
2. `android/key.properties` — a developer machine.
3. Neither: falls back to the **debug** keystore with a warning.

The fallback exists so an ordinary local build of a clean checkout still runs.
Such a build installs by hand and is correctly refused by Play Console. No
`.jks` and no `key.properties` is ever committed; both are gitignored.

CI takes the keystore from the `ANDROID_KEYSTORE_BASE64` secret and the three
password/alias secrets — unchanged from the Flutter build, so the existing
repository secrets keep working. See `.github/workflows/signed-aab.yml`, which
validates them up front: without that check the build does not fail, it quietly
produces a debug-signed bundle that Play rejects.

## iOS

| | |
|---|---|
| Bundle identifier | `com.crownparkcomputing.dosboxretro` |

Carried from the Flutter app's Xcode project, and the identity the App Store
listing is registered under. The SDL3 iOS build is not started yet; when it is,
it must adopt this identifier for the same reason Android keeps
`com.dosboxx.app` — anything else is a new app rather than an update.

Note that game downloads are compiled out on iOS (see
`media_downloads_available()`): artwork is metadata about software the user
already owns, whereas a storefront for the games themselves is not something
the App Store permits.
