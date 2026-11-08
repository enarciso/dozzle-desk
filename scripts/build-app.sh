#!/usr/bin/env bash
# Builds build/DozzleDesk.app with only the Command Line Tools (no Xcode), ad-hoc signed.
#   BUNDLE_ID=com.you.dozzledesk scripts/build-app.sh   # optional: your own bundle identifier
#   UNIVERSAL=1 scripts/build-app.sh                     # Apple silicon + Intel (used for releases)
set -euo pipefail
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-io.github.dozzledesk.DozzleDesk}"
cd "$(dirname "$0")/.."
APP=build/DozzleDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  # One build per architecture, then lipo; SwiftPM's multi-arch flag needs Xcode's build system.
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch"
  done
  lipo -create .build/arm64/release/DozzleDesk .build/x86_64/release/DozzleDesk \
       -output "$APP/Contents/MacOS/DozzleDesk"
else
  swift build -c release
  cp .build/release/DozzleDesk "$APP/Contents/MacOS/DozzleDesk"
fi
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: scripts/make-icon.sh
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>DozzleDesk</string>
  <key>CFBundleDisplayName</key><string>DozzleDesk</string>
  <key>CFBundleExecutable</key><string>DozzleDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>DozzleDesk connects to your Dozzle server on your local network to show container health.</string>
  <key>NSAppTransportSecurity</key>
  <!-- The server address is user-supplied and homelab Dozzles are often plain http on a LAN name. -->
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP $VERSION ($BUNDLE_ID, $(lipo -archs "$APP/Contents/MacOS/DozzleDesk"))"
