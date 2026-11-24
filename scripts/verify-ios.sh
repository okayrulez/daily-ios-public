#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm ci --ignore-scripts --no-audit --no-fund
npm run verify
cd ios
xcodegen generate
device_id="$(printenv DAILYX_SIMULATOR_ID || true)"
if [ -z "$device_id" ]; then
  device_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for rows in d.values() for x in rows if x["name"].startswith("iPhone")))')"
fi
xcodebuild build -project DailyX.xcodeproj -scheme DailyX \
  -destination "platform=iOS Simulator,id=$device_id" ONLY_ACTIVE_ARCH=YES -derivedDataPath ../build/DerivedData CODE_SIGNING_ALLOWED=NO
native_test_status=0
xcodebuild test -project DailyX.xcodeproj -scheme DailyX-CI \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath ../build/DerivedData -resultBundlePath "../build/DailyX-$(date +%Y%m%d-%H%M%S).xcresult" CODE_SIGNING_ALLOWED=NO 2>&1 | tee ../build/native-tests.log || native_test_status=$?


if [ "$native_test_status" -ne 0 ]; then
  echo "Native tests failed. Relevant failures follow:"
  python3 - <<'PYFAIL'
from pathlib import Path
import re
lines = Path('../build/native-tests.log').read_text(errors='replace').splitlines()
failures = [line for line in lines if re.search(r'error:|Test Case .* failed|TEST FAILED|Testing failed:', line)]
print('\n'.join(failures[-25:]) if failures else 'Open native-tests.log or the xcresult for the complete test failure.')
PYFAIL
  exit "$native_test_status"
fi

# Capture the actual SwiftUI writer with synthetic offline data for visual review.
if [ "${DAILYX_CAPTURE_PREVIEW:-0}" = "1" ]; then
  capture_dir="$(cd ../build && pwd)"
  xcrun simctl bootstatus "$device_id" -b
  xcrun simctl install "$device_id" ../build/DerivedData/Build/Products/Debug-iphonesimulator/DailyX.app
  xcrun simctl status_bar "$device_id" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
  xcrun simctl terminate "$device_id" com.okayrulez.daily || true
  xcrun simctl launch "$device_id" com.okayrulez.daily -daily-journal-preview
  sleep 3
  xcrun simctl io "$device_id" screenshot "$capture_dir/writing-preview.png"
  for stage in empty full; do
    xcrun simctl terminate "$device_id" com.okayrulez.daily
    xcrun simctl launch "$device_id" com.okayrulez.daily -daily-journal-preview "-daily-writing-$stage"
    sleep 2
    xcrun simctl io "$device_id" screenshot "$capture_dir/writing-preview-$stage.png"
  done
  xcrun simctl terminate "$device_id" com.okayrulez.daily
  xcrun simctl launch "$device_id" com.okayrulez.daily -daily-calendar-preview
  sleep 2
  xcrun simctl io "$device_id" screenshot "$capture_dir/writing-preview-calendar.png"
  for screen in changes setup sample settings history result analysis tour social; do
    xcrun simctl terminate "$device_id" com.okayrulez.daily
    xcrun simctl launch "$device_id" com.okayrulez.daily "-daily-$screen-preview"
    sleep 2
    xcrun simctl io "$device_id" screenshot "$capture_dir/writing-preview-$screen.png"
  done
fi
exit "$native_test_status"
