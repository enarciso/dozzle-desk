#!/usr/bin/env bash
# Runs the unit tests. Works with only the Command Line Tools installed (no Xcode) and with Xcode.
# CLT ships Swift Testing, but its macro plugin lives in a subfolder SwiftPM doesn't search, so
# point at it when it's there. Xcode's toolchain finds it on its own.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
args=()
if [[ -d "$DEV/usr/lib/swift/host/plugins/testing" ]]; then
  args+=(-Xswiftc -plugin-path -Xswiftc "$DEV/usr/lib/swift/host/plugins/testing")
fi
if [[ -d "$DEV/Library/Developer/Frameworks" ]]; then
  args+=(-Xlinker -rpath -Xlinker "$DEV/Library/Developer/Frameworks")
fi
exec swift test ${args[@]+"${args[@]}"} "$@"
