# DOSBox-X Android

Android launcher and handheld front-end for DOSBox-X, focused on DOS games and
Windows 98 CD game installs on devices such as the Retroid Pocket.

The app bundles the native DOSBox-X core and adds an Android-native launcher,
storage setup, CD archive management, per-game controls, and Win98 boot helpers.

## Features

- Unified games list for DOS folders, DOS CD games, Windows 98, and Win98 games.
- First-run storage wizard for choosing app-specific device or removable storage
  for `games/`, `cds/`, and imports.
- Storage manager for ZIP sources, kept extracted CDs, temporary extracts,
  visible CD images, installed games, and imports.
- CD archive workflow:
  - ZIP sources live under `cds/.archives/`.
  - one temporary extracted CD at a time under `cds/.prepared-cds/run_*`.
  - optional kept extracts under `cds/.extracted-cds/`.
  - kept extracts and source archives can both be selected from `+ Add CD game`.
- Windows 98 boot flow that mounts the selected CD as `D:` for installers that
  expect the CD-ROM there.
- Per-game metadata for DOS/Win98 type, CD/rip state, and remembered CD source.
- Per-game gamepad mappings and mouse/trackpad modes.
- Software Voodoo support through DOSBox-X for Glide-era games.

## Storage Layout

The setup wizard creates or selects an app-specific base folder. On removable
storage this is commonly:

```text
/storage/<card>/Android/data/com.dosboxx.app/files/
```

Inside that base folder:

```text
games/                 installed DOS games and the Win98 bundle
cds/                   visible standalone CD images only
cds/.archives/         reusable ZIP CD source packages
cds/.prepared-cds/     one temporary extracted CD mount at a time
cds/.extracted-cds/    optional kept extracted CD images
import/                transient imports
WinBox98/              Windows 98 disk images, if present
```

The visible launcher does not show ZIP sources directly. Use `+ Add CD game`
to select from the hidden archive collection or kept extracted CDs. New files
are imported through Android's system file picker, so the app does not request
broad external storage access.

## Windows 98 Notes

For Windows 98 CD setup, the launcher boots with:

- Win98 hard disk as `C:`
- selected CD-ROM as `D:`

This avoids installers failing because they expect the CD in `D:`. Install the
game into `C:\...` unless the game installer explicitly asks otherwise.

## Release Bundle

Signed Android App Bundles are produced by the GitHub Actions workflow
`Build signed Android App Bundle`.

Repository secrets required by the workflow:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The workflow uploads `app-release.aab` as a run artifact.

Optional Win98 image download:

- Add `WIN98_IMAGE_URL` as a repository secret to bake a default HTTPS URL into
  the app.
- The URL must point to a `.zip` or raw `.img`.
- ZIP archives should contain `windows98.img` or another OS-sized `.img`;
  optional boot floppies such as `WIN98C.IMG` can be included too.
- Users can also paste or replace the URL from the app's Storage screen.

## Project Layout

```text
app/src/main/java/com/dosboxx/app/
  GameLauncherActivity.java   launcher UI, storage manager, config generation
  GameImporter.java           Android file-picker import routing
  GameMeta.java               per-game platform/CD metadata
  KeyMapStore.java            per-game controls
  IsoReader.java              ISO9660 scan/extract helpers
  ZipToIso.java               ZIP folder to ISO helper
  Fat32Disk.java              FAT32 image creator/writer

app/src/main/java/org/libsdl/app/
  SDLActivity.java            SDL/DOSBox activity, overlay, input bridge

native/
  DOSBox-X upstream submodule and Android build notes
```

## GitHub Pages

The static project page lives in [`docs/index.md`](docs/index.md). In GitHub:

1. Open repository Settings.
2. Go to Pages.
3. Set Source to `Deploy from a branch`.
4. Select the default branch and `/docs`.

## Licensing And Store Distribution

GPL-2.0, matching DOSBox-X. See [`LICENSE`](LICENSE) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

GPLv2 allows paid distribution. A paid Play Store listing is acceptable provided
that buyers still receive the GPL rights, including access to the complete
corresponding source code and the right to copy, modify, and redistribute the
app under the GPLv2.

The app must not include Microsoft Windows images, game files, ROMs, BIOS files,
or other third-party content unless the distributor has the required rights.
