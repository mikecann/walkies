#!/bin/zsh
# Archive a Release build of Walkies for iOS, export it for App Store Connect and (with UPLOAD=1)
# upload it. Signing is automatic and cloud-managed, through the App Store Connect API key in
# ~/.config/poddle (no Xcode account or local distribution certificate needed).
#
#   scripts/appstore-upload.sh            archive, export and validate a signed .ipa; no upload
#   UPLOAD=1 scripts/appstore-upload.sh   the same, then upload it to App Store Connect
#
# Each run gets a new build number, the UTC time as YYMMDDHHMM (always increasing), unless
# BUILD_NUMBER is set. The version (MARKETING_VERSION, 1.0.0) comes from the project. Everything
# lands in OUT (default /tmp/walkies-appstore/<build>). VALIDATE=0 skips `altool --validate-app`.
# The API key is Poddle's team-wide one (same team), read from ~/.config/poddle and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."

ASC_KEY_ID=${ASC_KEY_ID:-7SS6J9F98P}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-69a6de6f-a06e-47e3-e053-5b8c7c11a4d1}
KEY_DIR=${KEY_DIR:-$HOME/.config/poddle}
ASC_KEY="$KEY_DIR/AuthKey_$ASC_KEY_ID.p8"
TEAM_ID=4DTAZSZL6B
BUILD=${BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}
OUT=${OUT:-/tmp/walkies-appstore/$BUILD}
DD=${DD:-/tmp/walkies-dd-appstore}
ARCHIVE="$OUT/Walkies.xcarchive"

[[ -f "$ASC_KEY" ]] || { echo "No App Store Connect API key at $ASC_KEY" >&2; exit 1; }
auth=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY"
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
mkdir -p "$OUT"
echo "Build number: $BUILD"

# The export options: App Store Connect distribution, Xcode-managed (cloud) signing.
export_options() {
  cat > "$OUT/ExportOptions-$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$1</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  echo "$OUT/ExportOptions-$1.plist"
}

echo "Archiving Release for iOS…"
xcodebuild archive -project Walkies.xcodeproj -scheme Walkies -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath "$DD" \
  CURRENT_PROJECT_VERSION="$BUILD" "${auth[@]}" > "$OUT/archive.log" 2>&1 \
  || { grep -E " error:|ARCHIVE FAILED" "$OUT/archive.log" >&2; echo "Archive failed, see $OUT/archive.log" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")
echo "Archived Walkies $VERSION ($BUILD)"
# The App Store build must only know about prod, and have none of the Debug-only screenshot
# mode or test sign-in in it.
BINARY="$ARCHIVE/Products/Applications/Walkies.app/Walkies"
if strings "$BINARY" | grep -q "resolute-pig-177"; then
  echo "The archive mentions the dev deployment (resolute-pig-177). Check Backend in Convex.swift." >&2; exit 1
fi
if strings "$BINARY" | grep -qE "WalkiesScreen|signInForTesting"; then
  echo "The archive has the screenshot mode or test sign-in in it. Is it a Release build?" >&2; exit 1
fi

echo "Exporting for App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$(export_options export)" "${auth[@]}" > "$OUT/export.log" 2>&1 \
  || { grep -E "error|EXPORT FAILED" "$OUT/export.log" >&2; echo "Export failed, see $OUT/export.log" >&2; exit 1; }
IPA="$OUT/export/Walkies.ipa"
echo "Signed: $IPA"
# What it's signed with: an Apple Distribution certificate and an App Store profile.
CHECK="$OUT/ipa-check"
rm -rf "$CHECK" && mkdir -p "$CHECK" && unzip -q "$IPA" -d "$CHECK"
codesign -dvv "$CHECK/Payload/Walkies.app" 2>&1 | grep -E "^Authority=" | head -1 || true
security cms -D -i "$CHECK/Payload/Walkies.app/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract Name raw -o - - 2>/dev/null | sed 's/^/Profile: /' || true

if [[ "${VALIDATE:-1}" == 1 ]]; then
  echo "Validating with App Store Connect…"
  # altool finds AuthKey_<id>.p8 in API_PRIVATE_KEYS_DIR.
  API_PRIVATE_KEYS_DIR="$KEY_DIR" xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee "$OUT/validate.log" | grep -vE "^\s*$" | tail -5
fi

if [[ "${UPLOAD:-0}" != 1 ]]; then
  echo "Stopping before the upload (UPLOAD=1 uploads). Build $BUILD is at $IPA"
  exit 0
fi

echo "Uploading build $BUILD to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/upload" \
  -exportOptionsPlist "$(export_options upload)" "${auth[@]}" 2>&1 | tee "$OUT/upload.log" \
  | grep -E "error|Upload succeeded|EXPORT SUCCEEDED|EXPORT FAILED|Uploaded"
echo "Uploaded Walkies $VERSION ($BUILD). It shows up under TestFlight once App Store Connect has processed it."
