#!/bin/sh
# Builds SnapSmith.app so macOS attributes Screen Recording permission to the app
# itself rather than to whichever terminal launched it.
set -eu
cd "$(dirname "$0")/.."

# Reverse-DNS identifier; set BUNDLE_ID to use your own (forks should).
BUNDLE_ID="${BUNDLE_ID:-id.selepaskerja.snapsmith}"

swift build -c release
APP=build/SnapSmith.app
rm -rf "$APP.prev"
[ -d "$APP" ] && mv "$APP" "$APP.prev"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SnapSmith "$APP/Contents/MacOS/SnapSmith"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>SnapSmith</string>
    <key>CFBundleExecutable</key><string>SnapSmith</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with the local certificate from scripts/make-signing-cert.sh when it exists: macOS
# then identifies the app by bundle ID + certificate, so Screen Recording permission
# survives rebuilds. Without it, fall back to ad-hoc signing, where the permission is
# tied to this exact build's code hash and any code change needs it granted again.
IDENTITY="SnapSmith Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    SIGN_AS="$IDENTITY"
else
    SIGN_AS="-"
    echo "Note: signing ad-hoc. Run scripts/make-signing-cert.sh once to keep permissions across rebuilds."
fi
BEFORE=$(codesign -d -r- "$APP.prev" 2>/dev/null | tail -1 || true)
codesign --force --sign "$SIGN_AS" "$APP"
AFTER=$(codesign -d -r- "$APP" 2>&1 | tail -1)
rm -rf "$APP.prev"
echo "Built $APP"
if [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ]; then
    echo "App identity changed: Screen Recording permission must be granted again."
    echo "Run: tccutil reset ScreenCapture $BUNDLE_ID"
fi
