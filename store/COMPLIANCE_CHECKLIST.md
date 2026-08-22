# Store submission checklist

No engineering change can guarantee approval; the final binary, metadata,
rights evidence and App Store Connect answers are all reviewed together. Do not
submit until every applicable item below is checked against the actual archive.

## Binary and behavior

- [ ] Clean install opens the compliance-first setup screen.
- [ ] Compliance Mode defaults to ON.
- [ ] The main GUI shows `COMPLIANCE MODE ACTIVE`.
- [ ] Games shows only `Retro-DosBox Homebrew Demo` while active.
- [ ] Paths and user-editable settings pages are absent, and the user library
      is neither read nor displayed.
- [ ] The FreeDOS image boots and RETRODEM.COM animates on a real iPhone/iPad.
- [ ] Turning compliance mode off reveals normal library/import behavior.
- [ ] Turning it on during a user session ends the session and hides all user
      content before returning to the isolated library.
- [ ] No yellow `Stub core` banner appears in the submitted build.
- [ ] App launch, background/resume, controller input and file import have been
      smoke-tested on every supported device family and orientation.

## Bundle audit

- [ ] Search the final `.ipa` for BIOS, ROM, game, Windows/DOS image and test
      files; only the documented `FREEDOS.IMG` and `RETRODEM.COM` may match.
- [ ] `FREEDOS.IMG` contains only the nine files documented in FREEDOS.txt.
- [ ] Rebuild the image with `tools/build-freedos-demo.sh` and compare SHA-256.
- [ ] GPL-2.0, MIT, FreeDOS provenance and source links are in the final bundle.
- [ ] The public source tag exactly matching the submitted build is available.
- [ ] `PrivacyInfo.xcprivacy` is at the app-bundle root and passes `plutil`.
- [ ] The archive contains only public iOS APIs and has no unexpected
      entitlements, tracking domains or background modes.

## App Store Connect

- [ ] App description and screenshots contain no third-party game assets,
      trademarks or claims of endorsement.
- [ ] Privacy answers match the released binary, including every SDK.
- [ ] Export-compliance answer matches
      `ITSAppUsesNonExemptEncryption = false`.
- [ ] Age rating reflects the app and any software the app itself offers.
- [ ] Support URL and privacy-policy URL are live and final.
- [ ] Review Notes use `store/review-notes.txt` and describe all emulator and
      file-import functionality under Guidelines 2.3.1, 4.7 and 5.2.
- [ ] If any downloadable software is added later, separately satisfy all of
      Guidelines 4.7.1–4.7.5; this build offers no downloads.

## Rights evidence

- [ ] Keep the official FreeDOS archive, published checksum and component
      source archives with release records.
- [ ] Keep authorship/source history for RETRODEM.COM.
- [ ] Do not add a self-dumped Saturn/console BIOS to any future store bundle
      without written redistribution rights from the rights holder.
