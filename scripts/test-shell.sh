#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"
derived="${TMPDIR:-/tmp}/usageink-shell-derived"
xcodebuild \
  -project UsageInk.xcodeproj \
  -scheme UsageInk \
  -destination "platform=macOS" \
  -derivedDataPath "$derived" \
  -jobs 3 \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test
