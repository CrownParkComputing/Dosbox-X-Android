#!/usr/bin/env bash
# Repair the IPA that tools/build-ios-app.sh (iosbox) produces.
#
# iosbox does not run Flutter's copyNativeCodeAssetsIOS. It copies each native
# asset into Frameworks/ as a bare .dylib and writes NativeAssetsManifest.json
# pointing at that bare name. iOS validates every nested Mach-O in Frameworks/
# as a code bundle, and a loose .dylib cannot be validated -- the device rejects
# the install with `ApplicationVerificationFailed` at ~80%, long after signing
# has succeeded, which makes it look like a signing fault. It is not.
#
# Flutter has already built the correct framework, at
# build/iosbox/flutter_assets/native_assets/<name>.framework -- iosbox just
# never bundles it. This swaps it in and rewrites the manifest to the layout
# flutter_tools itself emits (frameworkUri(): '<name>.framework/<name>',
# install name '@rpath/<name>.framework/<name>').
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/flutter_app/build/iosbox"
APP="$OUT/Runner.app"
MANIFEST="$APP/Frameworks/App.framework/flutter_assets/NativeAssetsManifest.json"

[ -d "$APP" ] || { echo "error: no $APP - run the iosbox build first." >&2; exit 1; }

shopt -s nullglob
frameworks=("$OUT/flutter_assets/native_assets/"*.framework)
if [ ${#frameworks[@]} -eq 0 ]; then
    echo "==> no native-asset frameworks; nothing to repair"
else
    for fw in "${frameworks[@]}"; do
        name="$(basename "$fw" .framework)"
        echo "==> installing $name.framework (replacing bare $name.dylib)"
        rm -rf "$APP/Frameworks/$name.framework"
        cp -a "$fw" "$APP/Frameworks/"
        rm -f "$APP/Frameworks/$name.dylib"
    done

    # The manifest maps the Dart asset id to a path the VM dlopens. iosbox
    # writes the bare dylib name; flutter_tools writes the framework-relative
    # path. They must agree with where the binary actually is.
    echo "==> rewriting NativeAssetsManifest.json"
    python3 - "$MANIFEST" <<'PY'
import json, sys, re

path = sys.argv[1]
with open(path) as f:
    manifest = json.load(f)

changed = []
for target, assets in manifest.get("native-assets", {}).items():
    for asset_id, entry in assets.items():
        # entry is [kind, path]; only the "absolute" bare-dylib form is wrong.
        if len(entry) != 2 or "/" in entry[1]:
            continue
        name = re.sub(r"\.dylib$", "", entry[1])
        name = re.sub(r"^lib", "", name)
        name = re.sub(r"[^A-Za-z0-9_-]", "", name)
        entry[1] = f"{name}.framework/{name}"
        changed.append(f"{asset_id} -> {entry[1]}")

with open(path, "w") as f:
    json.dump(manifest, f, separators=(",", ":"))

for line in changed:
    print(f"    {line}")
if not changed:
    print("    (already correct)")
PY
fi

# The emulator core, if it has been cross-built. Same rule as the native
# assets above: a framework bundle, never a loose dylib, or iOS rejects the
# install with ApplicationVerificationFailed. Its install name was already set
# to @rpath/libdosboxcore.framework/libdosboxcore at link time, so the path the
# app dlopens and the path it actually lives at agree.
CORE_DYLIB="$REPO_ROOT/native/dosbox_core/ios/build/out/libdosboxcore"
if [ -f "$CORE_DYLIB" ]; then
    echo "==> installing libdosboxcore.framework"
    FW="$APP/Frameworks/libdosboxcore.framework"
    rm -rf "$FW"
    mkdir -p "$FW"
    cp "$CORE_DYLIB" "$FW/libdosboxcore"
    cat > "$FW/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>libdosboxcore</string>
	<key>CFBundleIdentifier</key>
	<string>com.crownpark.retrodosbox.core</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>libdosboxcore</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>MinimumOSVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST
    echo "    $(du -h "$FW/libdosboxcore" | cut -f1)"
else
    echo "==> no iOS core at $CORE_DYLIB - the app will run on the stub"
fi

echo "==> repacking Runner.ipa"
rm -rf "$OUT/Payload"
mkdir -p "$OUT/Payload"
cp -a "$APP" "$OUT/Payload/"
( cd "$OUT" && rm -f Runner.ipa && zip -qry Runner.ipa Payload && rm -rf Payload )

echo "==> done"
ls -lh "$OUT/Runner.ipa"
