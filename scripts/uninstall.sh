#!/bin/sh
# Removes SnapSmith.
#
#   ./scripts/uninstall.sh            # remove the app only; settings and captures are kept
#   ./scripts/uninstall.sh --purge    # also remove settings, captures and the Screen Recording entry
set -eu

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
BUNDLE_ID="${BUNDLE_ID:-id.selepaskerja.snapsmith}"

pkill -x SnapSmith 2>/dev/null && sleep 1 || true
if [ -d "$INSTALL_DIR/SnapSmith.app" ]; then
    rm -rf "$INSTALL_DIR/SnapSmith.app"
    echo "Removed $INSTALL_DIR/SnapSmith.app"
else
    echo "No app found at $INSTALL_DIR/SnapSmith.app"
fi

if [ "${1:-}" = "--purge" ]; then
    defaults delete "$BUNDLE_ID" 2>/dev/null && echo "Removed settings" || true
    rm -rf "$HOME/Library/Application Support/SnapSmith" && echo "Removed captures and archive"
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 && echo "Cleared the Screen Recording entry" || true
    echo "The signing certificate \"SnapSmith Local Signing\" stays in your keychain; delete it in Keychain Access if you like."
else
    echo "Settings and captures were kept. Run with --purge to remove them too."
fi
