# Release status

Updated 2026-08-23.

## Done

**CI builds, signs and uploads.** A push to `main` produces a signed IPA and
delivers it to App Store Connect. Five separate faults sat between "the code
compiles" and that sentence, and each is commented where it was fixed:

1. `flutter build ipa` honours the project's Automatic signing and looks for a
   *development* certificate, which no runner has. Driving `xcodebuild`
   directly fixed it.
2. Signing settings on the xcodebuild command line apply to EVERY target,
   including CocoaPods ones, which reject a provisioning profile outright. The
   archive is unsigned now and `-exportArchive` does the signing.
3. `macos-14` carries Xcode 15.4, and Apple refuses anything built below the
   iOS 26 SDK -- reported only after the whole IPA has transferred.
4. Flutter 3.47 enables Swift Package Manager; `gamepads_ios` has not adopted
   it, and the mixed registrant fails to compile for device.
5. The runner has a dozen side-by-side Xcodes and only the DEFAULT one has its
   iOS platform components installed. Comparing major versions kept the first,
   which lists the SDK and cannot build for a device.

**Builds are VALID in App Store Connect** and attached to the 1.0 version.

The first delivery of each app succeeded and then vanished: the bundle embeds
DKImagePickerController via file_picker, which links the photo library APIs
whether the app calls them or not, and with no `NSPhotoLibraryUsageDescription`
that is ITMS-90683. Apple accepts the upload, discards the build in processing
and says so by email only, so CI stays green and nothing appears. CI now checks
the built bundle for that string, for `ITSAppUsesNonExemptEncryption` and for a
declared icon, so this fails the build rather than failing silently.

**Screenshots: 8 iPhone + 8 iPad, uploaded.** Captured by
`flutter_app/tool/screenshots.sh`, which drives the app through every screen
and writes them at the device's own pixel size -- 1320x2868 for the 6.9" iPhone
slot and 2064x2752 for the 13" iPad one, the only two sizes Apple still asks
for. Re-run it after any UI change.

**Listing metadata** is complete: description, keywords, promotional text,
support URL, subtitle, category, privacy policy URL, age rating, review contact
and review notes.

## Not done

**App Privacy.** Every API path for it returns 404 to this key -- including for
Retro-Amiga, which is in review, so the 404 says nothing about whether it is
answered. It has to be done in the browser: App Store Connect -> App Privacy.

**Submission.** Deliberately left alone. Everything is staged for review in
App Store Connect; pressing Submit is yours.

## Re-running the screenshots

    SHOT_SEED=<dir> flutter_app/tool/screenshots.sh <simulator-udid> <outdir>

`SHOT_SEED` holds fixtures copied into the app's Documents -- its CONTENTS
land there, so point it at the folder containing the app folder, not at the app
folder itself. `SHOT_SKIP_RUNNING=1` skips the launch-a-title shot, which boots
the real core and can outlast the driver's connection.
