#!/usr/bin/env bash
# SpotlessMac release pipeline:
#   archive → export (Developer ID) → notarize → staple → DMG → notarize DMG
#
# Prerequisites:
#   - Xcode command-line tools
#   - "Developer ID Application" certificate in your login Keychain
#   - notarytool credentials stored in Keychain (run the store-credentials command below once)
#   - create-dmg:  brew install create-dmg
#
# One-time notarytool credential setup:
#   xcrun notarytool store-credentials "$NOTARYTOOL_PROFILE" \
#     --apple-id "your@apple.id" \
#     --team-id "$TEAM_ID" \
#     --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com

set -euo pipefail

# ── TODO: fill in these four values ─────────────────────────────────────────
# Full string as shown in Keychain Access → "Developer ID Application: ..."
DEVELOPER_ID_APP="Developer ID Application: TODO_YOUR_NAME (TODO_TEAM_ID)"
# 10-character Team ID from https://developer.apple.com/account → Membership
TEAM_ID="TODO_10_CHARS"
# Name you chose when running notarytool store-credentials
NOTARYTOOL_PROFILE="spotlessmac-notary"
# ────────────────────────────────────────────────────────────────────────────

APP_NAME="SpotlessMac"
PROJECT="${APP_NAME}.xcodeproj"
SCHEME="${APP_NAME}"
ARCHIVE="build/${APP_NAME}.xcarchive"
EXPORT_DIR="build/${APP_NAME}-export"
APP="${EXPORT_DIR}/${APP_NAME}.app"
ZIP="build/${APP_NAME}.zip"
DMG="${APP_NAME}.dmg"

mkdir -p build

# ── 1. Archive ───────────────────────────────────────────────────────────────
# Compiles the app and embeds the Developer ID signature into the archive.
echo "==> [1/9] Archiving…"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID"

# ── 2. Export ────────────────────────────────────────────────────────────────
# Extracts the .app and re-signs it for Developer ID distribution using
# the settings in ExportOptions.plist (method = developer-id).
echo "==> [2/9] Exporting…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions.plist

# ── 3. Verify codesign ───────────────────────────────────────────────────────
# --deep checks every nested bundle/framework/helper.
# --strict catches any unsigned component that would fail Gatekeeper.
echo "==> [3/9] Verifying codesign…"
codesign --verify --deep --strict --verbose=2 "$APP"

# ── 4. Pre-notarization spctl check ─────────────────────────────────────────
# At this stage the app is signed but not yet notarized, so spctl will
# report "not notarized". That is expected — the || true suppresses the
# non-zero exit so the script keeps going.
echo "==> [4/9] spctl pre-check (expected 'not notarized' at this stage)…"
spctl --assess --type exec --verbose "$APP" || true

# ── 5. Zip for notarytool ────────────────────────────────────────────────────
# ditto preserves HFS+ resource forks and extended attributes.
echo "==> [5/9] Zipping for notarization…"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── 6. Submit to Apple Notary Service ────────────────────────────────────────
# --wait blocks until Apple returns a result (approved / invalid).
# Typical turnaround: under 2 minutes.
echo "==> [6/9] Notarizing app…"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

# ── 7. Staple ────────────────────────────────────────────────────────────────
# Attaches the notarization ticket to the .app so Gatekeeper can verify
# it offline (no network needed on the end user's machine).
echo "==> [7/9] Stapling app…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"   # exits 0 = success

# ── 8. Create DMG ────────────────────────────────────────────────────────────
echo "==> [8/9] Creating DMG…"
# Remove stale DMG if present (create-dmg refuses to overwrite)
rm -f "$DMG"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "${APP_NAME}.app" 175 190 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 425 190 \
  "$DMG" \
  "${EXPORT_DIR}/"

# Sign the DMG with a secure timestamp (required for notarization).
codesign --sign "$DEVELOPER_ID_APP" --timestamp "$DMG"

# ── 9. Notarize + staple DMG ─────────────────────────────────────────────────
echo "==> [9/9] Notarizing and stapling DMG…"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "✅  Done!  ${DMG} is ready for distribution."
echo ""
echo "Final verification:"
echo "  spctl --assess --type exec --verbose \"${APP}\""
echo "  codesign -d --entitlements :- \"${APP}\""
