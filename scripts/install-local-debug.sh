#!/usr/bin/env bash
#
# Build a signed Debug build of SpotlessMac and install it to /Applications.
#
# Debug configuration keeps the `#if DEBUG` license bypass active (LicenseManager.canClean
# returns true unconditionally), while signing with a stable Apple Development identity
# (team + certificate) keeps the app's Designated Requirement constant across rebuilds —
# unlike ad-hoc DerivedData builds (e.g. plain ⌘R with no Team set, or
# CODE_SIGNING_ALLOWED=NO), whose identity changes every build and resets the
# "Full Disk Access" TCC grant.
#
# Usage:
#   ./scripts/install-local-debug.sh
#   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/install-local-debug.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SpotlessMac.xcodeproj"
SCHEME="SpotlessMac"
ENTITLEMENTS="SpotlessMac/SpotlessMac.entitlements"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/Build/Products/Debug/SpotlessMac.app"
DEST="/Applications/SpotlessMac.app"

# Resolve the signing identity: explicit override, else first Apple Development cert.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Apple Development" | head -n1 | sed -E 's/.*"(.*)"/\1/')
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "error: no Apple Development signing identity found." >&2
    echo "       Set SIGN_IDENTITY=\"Apple Development: ...\" and retry." >&2
    exit 1
fi
echo "==> Signing identity: $SIGN_IDENTITY"

echo "==> Building Debug (unsigned)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -derivedDataPath "$BUILD_DIR" -destination "platform=macOS" \
    CODE_SIGNING_ALLOWED=NO build

echo "==> Signing…"
codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"
codesign --verify --strict "$APP_PATH"

echo "==> Quitting previous instance (if running)…"
osascript -e 'quit app "SpotlessMac"' >/dev/null 2>&1 || true
sleep 0.3

echo "==> Installing to $DEST …"
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"

echo "==> Launching…"
open "$DEST"

echo "Done. License check is bypassed (Debug build)."
echo "If FDA is needed: System Settings → Privacy → Full Disk Access → +"
echo "     and add $DEST (the grant persists across rebuilds with the same SIGN_IDENTITY)."
