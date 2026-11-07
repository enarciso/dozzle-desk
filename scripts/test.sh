#!/usr/bin/env bash
# Runs the unit tests with only the Command Line Tools installed (no Xcode).
# CLT ships Swift Testing, but its macro plugin lives in a subfolder SwiftPM doesn't search.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
exec swift test \
  -Xswiftc -plugin-path -Xswiftc "$DEV/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$DEV/Library/Developer/Frameworks" "$@"
