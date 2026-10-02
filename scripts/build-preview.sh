#!/usr/bin/env bash
# Build a standalone, ad-hoc signed Debug preview in a new temporary folder.
# Usage: build-preview.sh [existing.app]
# Does not install, launch, delete files, or change the installed app/FDA grant.
set -euo pipefail

if (( $# > 1 )); then
    printf 'Usage: %s [existing.app]\n' "$0" >&2
    exit 2
fi
spotless_preview_source="${1:-}"
if [[ -n "$spotless_preview_source" && -d "$spotless_preview_source" ]]; then
    spotless_preview_source=$(cd "$spotless_preview_source" && pwd -P)
fi
cd "$(dirname "$0")/.."
spotless_preview_root=$(mktemp -d /private/tmp/spotlessmac-preview.XXXXXX)
if [[ -n "$spotless_preview_source" ]]; then
    if [[ ! -d "$spotless_preview_source" || ! -f "$spotless_preview_source/Contents/Info.plist" ]]; then
        printf 'Not an app bundle: %s\n' "$spotless_preview_source" >&2
        exit 2
    fi
    spotless_preview_app="$spotless_preview_root/SpotlessMac.app"
    ditto "$spotless_preview_source" "$spotless_preview_app"
else
spotless_preview_args=(
    -project SpotlessMac.xcodeproj -scheme SpotlessMac
    -configuration Debug -destination 'platform=macOS'
    -derivedDataPath "$spotless_preview_root/DerivedData"
    CODE_SIGNING_ALLOWED=NO
)
# Needed only in restricted compiler environments; leaves product settings intact.
if [[ "${SPOTLESSMAC_DISABLE_MACRO_SANDBOX:-0}" == 1 ]]; then
    spotless_preview_args+=('OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox')
fi
xcodebuild "${spotless_preview_args[@]}" build > "$spotless_preview_root/build.log" 2>&1 || {
    tail -n 60 "$spotless_preview_root/build.log" >&2
    exit 1
}
spotless_preview_app="$spotless_preview_root/DerivedData/Build/Products/Debug/SpotlessMac.app"
fi
# Seal the complete bundle; linker-only signatures from unsigned builds are incomplete.
codesign --force --deep --sign - "$spotless_preview_app"
codesign --verify --deep --strict --verbose=2 "$spotless_preview_app"
printf 'Preview: %s\n' "$spotless_preview_app"
if [[ -f "$spotless_preview_root/build.log" ]]; then
    printf 'Build log: %s\n' "$spotless_preview_root/build.log"
fi
