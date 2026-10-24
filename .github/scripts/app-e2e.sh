#!/usr/bin/env bash
# Runs inside the emulator: drives the real app against the backend on the host (10.0.2.2:4000).
set -o pipefail
mkdir -p ci-app
adb logcat -c || true
# the app was built before the emulator started (see the workflow); just install and drive it
(cd mobile && timeout 1800 flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/app_test.dart \
  --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk \
  --dart-define=API_BASE=http://10.0.2.2:4000 \
  -d emulator-5554 2>&1) | tee ci-app/drive.txt
rc=$?
adb logcat -d > ci-app/logcat-full.txt 2>&1 || true
grep -E " (E|F) |flutter" ci-app/logcat-full.txt | grep -v "EGL\|audit" | tail -300 > ci-app/logcat.txt || true
echo "drive_rc=$rc" > ci-app/drive_rc.txt
exit 0
