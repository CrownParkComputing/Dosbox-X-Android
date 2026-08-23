# Release status and the last mile

Written 2026-08-23. What is done, what is not, and the exact steps that finish
it. The same document exists in Retro-Dosbox, because the two apps are in the
same position.

## Done

**The app builds and runs on iOS.** It could not before, for three separate
reasons, all fixed:

- `SUPPORTED_PLATFORMS` was `iphoneos` alone, so no simulator build was
  possible whatever flag was passed.
- The emulator core was never embedded at all. The Embed Frameworks phase was
  empty, and the dylib was injected into the IPA *after* the build by
  `tools/fix-ipa-native-assets.sh` -- which cannot work under any cloud build,
  since CI produces the IPA and uploads it with nothing in between. Every
  cloud build shipped an app reporting "Stub core: libdosboxcore not found".
- The core had no Mac-native build. `build-ios.sh` needs Docker and an iOS SDK
  unpacked by hand into a named volume; neither exists on a Mac or in a CI
  image. `native/dosbox_core/ios/build-ios-macos.sh` builds it natively, for
  device or simulator (`IOS_PLATFORM=iphonesimulator`).

**The core is committed as an xcframework** carrying both device and simulator
slices, embedded by Xcode's Embed Frameworks phase. Verified at runtime:
`dosbox_core_start` resolves via `dlopen` on a simulator.

**It runs with nothing supplied.** A PC needs no ROM -- DOSBox-X provides the
DOS itself -- and the app now ships `DEMO.COM` (written for this app) plus an
unmodified FreeDOS 1.3 boot floppy, selectable on the Compliance page.
Compliance mode scans a directory holding only the bundled demo, under
Application Support rather than Documents, so a user file cannot reach it.

**The bundle ID** is `com.crownparkcomputing.dosboxretro`, matching the App
Store record. It was `com.crownpark.retrodosbox`, which matched nothing.

**CI builds and uploads.** `.github/workflows/ios.yml` signs and uploads to
App Store Connect on push to `main`, and skips signing when the secrets are
absent so forks still get a compile check.

**The store listing** has description, keywords, promotional text, support
URL, review contact, review notes, free pricing, age rating, categories,
subtitle, privacy policy URL and content rights -- all set through the API.

**No reviewer test material is needed.** The app runs with nothing supplied,
which is what the review notes and the Compliance page both say.

**Provisioning profile** `Retro-Dosbox AppStore` created, ACTIVE, exported to
`~/Documents/ios-signing/Retro-Dosbox.mobileprovision(.base64)` and installed
locally.

## Not done, and why

**No build has reached App Store Connect yet.** CI cannot sign until two
secrets exist, and they cannot be produced without the signing keychain's
password.

**No screenshots.** The listing needs at least one.

**App Privacy** is unanswered. Every API path for it returns 404 to this key,
so it is browser-only: App Store Connect -> App Privacy.

## The last mile

### 1. Unlock the signing keychain

The distribution identity is shared across the family and lives in
`c64retro-signing.keychain-db`. Exporting it needs that keychain's password.

```sh
security unlock-keychain ~/Library/Keychains/c64retro-signing.keychain-db

# Also repairs LOCAL signing, which fails with errSecInternalComponent
# without it: the key imports, `security find-identity` calls it valid, and
# every signing attempt fails anyway.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k 'KEYCHAIN_PASSWORD' ~/Library/Keychains/c64retro-signing.keychain-db
```

If that password is lost the certificate cannot be exported and must be
revoked and reissued. It still appears healthy in `find-identity` either way,
so a lost password looks like a working certificate right up until this step.

### 2. Export the certificate

```sh
security export -k ~/Library/Keychains/c64retro-signing.keychain-db \
  -t identities -f pkcs12 -P 'CHOOSE_A_PASSWORD' \
  -o ~/Documents/ios-signing/dist.p12

base64 -i ~/Documents/ios-signing/dist.p12 | pbcopy
```

`CHOOSE_A_PASSWORD` does not exist yet -- you invent it here, and it is only
what CI uses to import the `.p12`.

### 3. Set the remaining repository secrets

Settings -> Secrets and variables -> Actions. Three are already set
(`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`).

| Secret | Value |
|---|---|
| `APPSTORE_CERT_BASE64` | the base64 from step 2 |
| `APPSTORE_CERT_PASSWORD` | the password chosen in step 2 |
| `APPSTORE_PROFILE_BASE64` | contents of `~/Documents/ios-signing/Retro-Dosbox.mobileprovision.base64` |

The profile secret cannot be shared between apps: each bundle ID needs its
own. Retro-Dosbox has its own file in the same directory.

### 4. Push, and the build uploads itself

Any push to `main` now builds, signs and uploads. The build number is a UTC
timestamp, because App Store Connect refuses a `CFBundleVersion` it has seen
before and only says so after the whole upload has transferred.

### 5. Finish the listing in the browser

- **App Privacy** -- required, and not reachable through the API.
- **Screenshots** -- at least one.
- Attach the build, then submit.
