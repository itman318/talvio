#!/usr/bin/env bash
# Runs inside the emulator: drives the real app against the backend on the host (10.0.2.2:4000).
# Drives the server flows on the emulator.
set -o pipefail
mkdir -p ci-app
run() { # $1 = test file, $2 = prebuilt apk, $3 = log name
  adb logcat -c || true
  (cd mobile && timeout 1200 flutter drive \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/$1 \
    --use-application-binary=../$2 \
    --dart-define=API_BASE=http://10.0.2.2:4000 \
    -d emulator-5554 2>&1) | tee ci-app/$3.txt
  local rc=$?
  adb logcat -d > ci-app/logcat-$3.txt 2>&1 || true
  return $rc
}
run app_test.dart app-test.apk drive; rc1=$?
adb wait-for-device || true
rc2=0
cp ci-app/drive.txt ci-app/drive-all.txt 2>/dev/null || true
rc=$(( rc1 != 0 ? rc1 : rc2 ))
echo "drive_rc=$rc app=$rc1" > ci-app/drive_rc.txt
exit 0
