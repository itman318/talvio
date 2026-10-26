#!/usr/bin/env bash
# Runs inside the emulator: drives the real app against the backend on the host (10.0.2.2:4000).
# Drives the server flows on the emulator.
set -o pipefail
mkdir -p ci-app
run() { # $1 = test file, $2 = prebuilt apk, $3 = log name
  adb logcat -c || true
  # stream the log while the test runs: if the emulator itself dies we still keep what happened
  adb logcat -v time > ci-app/logcat-live-$3.txt 2>&1 &
  local lc=$!
  # watchdog: host memory, emulator process and app memory every 15 s
  ( while true; do
      echo "== $(date -u +%T)"; free -m | sed -n 2p
      ps -eo pid,rss,pcpu,comm --sort=-rss | head -4
      timeout 10 adb shell dumpsys meminfo com.talvio.app 2>/dev/null | grep -E "TOTAL|Native Heap|Graphics" | head -3
      sleep 15
    done ) > ci-app/watch-$3.txt 2>&1 &
  local wd=$!
  (cd mobile && timeout 1200 flutter drive \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/$1 \
    --use-application-binary=../$2 \
    --dart-define=API_BASE=http://10.0.2.2:4000 \
    -d emulator-5554 2>&1) | tee ci-app/$3.txt
  local rc=$?
  kill $lc $wd 2>/dev/null || true
  sudo dmesg 2>/dev/null | grep -iE "oom|killed process" | tail -10 > ci-app/oom-$3.txt || true
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
