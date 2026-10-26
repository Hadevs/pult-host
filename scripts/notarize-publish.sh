#!/usr/bin/env bash
# One-shot: notarize the already-built, Developer-ID-signed Pult.app, staple
# it, upload the zip + appcast to the update server, and publish a GitHub
# release. Run it on the Mac that built dist/Pult.app.
#
#   bash scripts/notarize-publish.sh
#
# It fetches the App Store Connect key from appkit-server (your own key) only
# for the notarytool call and deletes it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Pult.app"
KEY_ID="S7326YV324"
ISSUER="af737184-83bd-4d0f-8531-b6a27f27d226"
KEY_REMOTE="appkit-server:/var/www/appkit/data/apple-keys/1/877111d8cec67bf920ab43597cd1e736_AuthKey_${KEY_ID}.p8"
SITE_HOST="appkit-server"
SITE_PATH="/var/www/pult"
SITE_URL="https://pult.209-74-79-242.sslip.io"

[ -d "$APP" ] || { echo "No $APP — build it first (scripts/release.sh or the archive step)."; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
ZIP="dist/Pult-$VERSION.zip"
echo "==> Pult $VERSION ($BUILD)"

echo "==> Fetching notarization key"
KEY=$(mktemp /tmp/pult_asc.XXXXXX.p8)
trap 'rm -f "$KEY"' EXIT
scp -q "$KEY_REMOTE" "$KEY"

echo "==> Zipping and notarizing (waits for Apple)…"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait

echo "==> Stapling and re-zipping"
xcrun stapler staple "$APP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP" || true   # expect: accepted, Notarized Developer ID

echo "==> Writing appcast.json"
cat > dist/appcast.json <<JSON
{"version":"$VERSION","build":$BUILD,"url":"$SITE_URL/Pult-$VERSION.zip","notes":"Pult host $VERSION"}
JSON

echo "==> Uploading to the update server"
scp -q "$ZIP" dist/appcast.json "$SITE_HOST:$SITE_PATH/"
ssh "$SITE_HOST" "chown www-data:www-data $SITE_PATH/Pult-$VERSION.zip $SITE_PATH/appcast.json"

echo "==> Publishing GitHub release v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo Hadevs/pult-host \
  --title "Pult $VERSION" --notes "Notarized Mac host. Download Pult-$VERSION.zip, unzip, move to Applications." \
  || gh release upload "v$VERSION" "$ZIP" --repo Hadevs/pult-host --clobber

echo "==> Done. Live: $SITE_URL  ·  https://github.com/Hadevs/pult-host/releases/latest"
