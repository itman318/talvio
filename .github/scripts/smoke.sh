#!/usr/bin/env bash
# Installs the release APK on the emulator, launches it, and collects a screenshot + logcat.
set -x
OUT=ci-smoke
mkdir -p $OUT
adb wait-for-device
adb shell getprop ro.product.cpu.abilist > $OUT/abi.txt
adb install -r talvio.apk > $OUT/install.txt 2>&1
PKG=$(adb shell pm list packages | grep -i talvio | head -1 | sed 's/package://' | tr -d '\r')
echo "package=$PKG" >> $OUT/install.txt
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >> $OUT/install.txt 2>&1
sleep 15
adb exec-out screencap -p > $OUT/screen-15s.png
sleep 30
adb exec-out screencap -p > $OUT/screen-45s.png
adb logcat -d > $OUT/logcat-full.txt
grep -iE "flutter|AndroidRuntime|FATAL|talvio|chatapp|Exception|Error" $OUT/logcat-full.txt | tail -400 > $OUT/logcat.txt
adb shell pidof "$PKG" > $OUT/pid.txt 2>&1 || echo "not running" > $OUT/pid.txt
exit 0
