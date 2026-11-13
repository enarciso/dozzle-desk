#!/usr/bin/env bash
# Builds the downloadable release: a universal (Apple silicon + Intel), ad-hoc signed
# DozzleDesk.app zipped into dist/, plus a SHA-256 checksum file.
#   scripts/release.sh 0.1.0
# The Release workflow (.github/workflows/release.yml) runs this on GitHub for every version tag.
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh VERSION   e.g. 0.1.0}"
cd "$(dirname "$0")/.."

scripts/test.sh
VERSION="$VERSION" UNIVERSAL=1 scripts/build-app.sh

APP=build/DozzleDesk.app
codesign --verify --strict "$APP"
archs=$(lipo -archs "$APP/Contents/MacOS/DozzleDesk")
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "not universal: $archs" >&2; exit 1; }
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$plist_version" == "$VERSION" ]] || { echo "Info.plist says $plist_version" >&2; exit 1; }

mkdir -p dist
ZIP="dist/DozzleDesk-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle's symlinks, permissions and signature intact (plain zip can break them).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo "release artifacts:"
ls -l "$ZIP" "$ZIP.sha256"
cat "$ZIP.sha256"
