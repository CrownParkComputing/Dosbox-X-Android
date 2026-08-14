#!/usr/bin/env bash
# Integration test: does DOS actually fire up on the connected device?
#
# Drives the installed debug app (com.dosboxx.app.test) through its boottest
# door: MainActivity writes a conf whose autoexec runs
#   echo OK > C:\BOOTOK.TXT
# with C: mounted on <externalFiles>/boottest. The marker file appearing on
# the Android filesystem proves, mechanically: libmain loaded, launcher conf
# parsed (patch 0003), drive mounted, DOS booted, COMMAND.COM executed a
# command. No screenshots, no eyeballs.
#
# Usage: tools/boot-test.sh            (app already installed)
#        tools/boot-test.sh --install  (flutter build + install first)
set -u

PKG=com.dosboxx.app.test
EXT=/storage/emulated/0/Android/data/$PKG/files
MARKER=$EXT/boottest/BOOTOK.TXT
LOG=$EXT/dosbox-stdout.log
TIMEOUT=60

here="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--install" ]; then
    (cd "$here/flutter_app" && flutter build apk --debug) || exit 1
    adb install -r "$here/flutter_app/build/app/outputs/flutter-apk/app-debug.apk" || exit 1
fi

adb get-state >/dev/null 2>&1 || { echo "FAIL: no device"; exit 1; }

# Screen must be on for the emulator activity to resume and draw.
adb shell input keyevent KEYCODE_WAKEUP
adb shell rm -f "$MARKER" "$LOG" 2>/dev/null
adb shell am force-stop $PKG
adb shell am start -n $PKG/com.dosboxx.dosboxx_launcher.MainActivity --ez boottest true >/dev/null || {
    echo "FAIL: could not start MainActivity (is the debug app installed?)"; exit 1; }

echo "waiting for DOS to boot and write C:\\BOOTOK.TXT ..."
for i in $(seq $TIMEOUT); do
    if adb shell "test -f $MARKER" 2>/dev/null; then
        echo "PASS: DOS booted and ran autoexec in ${i}s"
        adb shell am force-stop $PKG
        exit 0
    fi
    sleep 1
done

echo "FAIL: no BOOTOK.TXT after ${TIMEOUT}s"
echo "--- how far the core got ($LOG):"
adb shell "tail -15 $LOG" 2>/dev/null || echo "(no core log at all - libmain never reached main())"
adb shell am force-stop $PKG
exit 1
