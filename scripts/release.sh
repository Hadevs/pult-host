#!/usr/bin/env bash
# Build, Developer ID sign, notarize, staple, zip the Pult host, and write
# appcast.json next to the zip. Run on a Mac, or in CI (see release.yml).
#
# Required environment:
#   DEVELOPER_ID   e.g. "Developer ID Application: Basil Tsironis (TEAMID)"
#   TEAM_ID        the Developer ID team id
#   AC_API_KEY_ID / AC_API_ISSUER_ID / AC_API_KEY_P8   App Store Connect key for notarytool
# Optional:
#   VERSION  marketing version (default: from the built app)
#   APPCAST_BASE_URL  where the zip will live (default: the Pult site)
set -euo pipefail

cd "$(dirname "$0")/.."
APPCAST_BASE_URL="${APPCAST_BASE_URL:-https://pult.209-74-79-242.sslip.io}"
OUT="dist"; rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> Generating project"
xcodegen generate

echo "==> Archiving"
xcodebuild -project Pult.xcodeproj -scheme PultHost -configuration Release \
  -archivePath "$OUT/Pult.xcarchive" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  archive

APP="$OUT/Pult.app"
cp -R "$OUT/Pult.xcarchive/Products/Applications/Pult.app" "$APP"

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
echo "==> Pult $VERSION ($BUILD)"

echo "==> Notarizing"
ZIP="$OUT/Pult-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
KEY_FILE="$(mktemp)"; printf '%s' "$AC_API_KEY_P8" > "$KEY_FILE"
xcrun notarytool submit "$ZIP" \
  --key "$KEY_FILE" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" --wait
rm -f "$KEY_FILE"

echo "==> Stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"; /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip the stapled app

echo "==> Writing appcast.json"
cat > "$OUT/appcast.json" <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$APPCAST_BASE_URL/Pult-$VERSION.zip",
  "notes": "Pult host $VERSION"
}
JSON

echo "==> Verifying signature & notarization"
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP" || true

echo "==> Done. Upload these to $APPCAST_BASE_URL :"
ls -1 "$OUT"/Pult-*.zip "$OUT"/appcast.json
