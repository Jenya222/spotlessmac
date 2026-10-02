#!/bin/bash
# Usage: scripts/test.sh [TestClass ...]   (no args = whole SpotlessMacTests target)
set -o pipefail
cd "$(dirname "$0")/.."
args=()
for c in "$@"; do args+=("-only-testing:SpotlessMacTests/$c"); done
xcodebuild test -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO "${args[@]}" 2>&1 \
  | grep -E "error:|Test Case .*(passed|failed)|Executed [0-9]+ test|\*\* TEST (SUCCEEDED|FAILED) \*\*|BUILD FAILED"
