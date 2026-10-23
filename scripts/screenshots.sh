#!/usr/bin/env bash
# App Store screenshots: builds Walkies (Debug) for the simulator, opens each screen straight
# away with -WalkiesScreen and saves a screenshot of each to appstore/screenshots/. Everything
# on screen is sample data (Walkies/Services/ScreenshotMode.swift): a made-up explorer a few
# weeks into Fremantle, WA, from appstore/sample/fremantle.json. Never anyone's real walks.
# The status bar is set to 9:41 with full battery and signal.
#
#   scripts/screenshots.sh                       # every screen, iPhone 17 Pro Max (1320 x 2868)
#   scripts/screenshots.sh map recap             # just these
#   SKIP_BUILD=1 scripts/screenshots.sh          # reuse the last build
#   DEVICE="iPhone 17 Pro" OUT=/tmp/shots scripts/screenshots.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DEVICE=${DEVICE:-"iPhone 17 Pro Max"}
OS=${OS:-27.0}
OUT=${OUT:-"$ROOT/appstore/screenshots"}
DERIVED="$ROOT/build/DerivedData"
BUNDLE=com.mikecann.walkies
SAMPLE="$ROOT/appstore/sample/fremantle.json"
WAIT=${WAIT:-8}

ALL=(map recap secrets progress quests walks)
SCREENS=("$@")
[ ${#SCREENS[@]} -eq 0 ] && SCREENS=("${ALL[@]}")
[ -f "$SAMPLE" ] || { echo "No sample at $SAMPLE (node scripts/make-screenshot-sample.mjs)" >&2; exit 1; }

# Find (or make) a simulator for this device and OS.
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
d = json.load(sys.stdin)['devices']
for runtime, devs in d.items():
    if runtime.endswith('iOS-' + '$OS'.replace('.', '-')):
        for dev in devs:
            if dev['name'] == '$DEVICE':
                print(dev['udid']); sys.exit()
")
if [ -z "$UDID" ]; then
  TYPE=$(xcrun simctl list devicetypes -j | python3 -c "
import json, sys
for t in json.load(sys.stdin)['devicetypes']:
    if t['name'] == '$DEVICE': print(t['identifier'])
")
  UDID=$(xcrun simctl create "$DEVICE" "$TYPE" "com.apple.CoreSimulator.SimRuntime.iOS-${OS//./-}")
fi
echo "Simulator: $DEVICE ($OS) $UDID"

if [ -z "${SKIP_BUILD:-}" ]; then
  xcodebuild -project Walkies.xcodeproj -scheme Walkies -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" build -quiet
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Walkies.app"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl install "$UDID" "$APP"
# The sample goes in the app's own Application Support, where ScreenshotMode looks for it.
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
mkdir -p "$DATA/Library/Application Support"
cp "$SAMPLE" "$DATA/Library/Application Support/ScreenshotSample.json"
# Grant what the first run would ask for, so no permission prompt covers a screenshot.
xcrun simctl privacy "$UDID" grant location-always "$BUNDLE" 2>/dev/null || true
xcrun simctl privacy "$UDID" grant motion "$BUNDLE" 2>/dev/null || true
mkdir -p "$OUT"

for screen in "${SCREENS[@]}"; do
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  # -setupDone skips the first run; the book opens with the area that has the most finds.
  xcrun simctl launch "$UDID" "$BUNDLE" -WalkiesScreen "$screen" -setupDone YES \
    -secretsBookSort mostFound -secretsBookFilter all >/dev/null
  wait=$WAIT
  # The map's satellite tiles take a moment, and the walk replay plays through first.
  case "$screen" in map) wait=$((WAIT + 6)) ;; recap) wait=$((WAIT + 14)) ;; esac
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$screen.png" >/dev/null 2>&1
  echo "  $OUT/$screen.png $(sips -g pixelWidth -g pixelHeight "$OUT/$screen.png" | awk '/pixel/ {printf "%s ", $2}')"
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
