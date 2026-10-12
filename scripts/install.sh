#!/bin/sh
# One-step install: builds SnapSmith, signs it, copies it to /Applications and opens it.
#
#   ./scripts/install.sh                          # install to /Applications
#   INSTALL_DIR="$HOME/Applications" ./scripts/install.sh   # install somewhere else
#
# Safe to re-run: it quits the running app and replaces it with the freshly built one.
set -eu
cd "$(dirname "$0")/.."

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
CERT_NAME="SnapSmith Local Signing"

step() { printf '\n==> %s\n' "$1"; }

step "Checking for the Swift toolchain"
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift isn't installed. Run this once, then run ./scripts/install.sh again:"
    echo "    xcode-select --install"
    exit 1
fi

# A stable signing certificate lets macOS keep the Screen Recording permission across rebuilds.
if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    step "Creating a local signing certificate (macOS will ask for your password once)"
    ./scripts/make-signing-cert.sh || echo "Continuing without it: the app will be signed ad-hoc."
fi

step "Building SnapSmith (the first build takes a minute or two)"
./scripts/bundle.sh

step "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
pkill -x SnapSmith 2>/dev/null && sleep 1 || true
rm -rf "$INSTALL_DIR/SnapSmith.app"
ditto build/SnapSmith.app "$INSTALL_DIR/SnapSmith.app"

if [ -z "${NO_OPEN:-}" ]; then
    open "$INSTALL_DIR/SnapSmith.app"
fi

cat <<MSG

Done. SnapSmith is in your menu bar (camera icon, top right).

First launch: macOS asks for Screen Recording permission. Turn on SnapSmith in
System Settings > Privacy & Security > Screen Recording, then quit and reopen it.

Then press  Option + Shift + 4  and drag over something to try it.
MSG
