#!/usr/bin/env bash
# Builds build/DozzleDesk.app with only the Command Line Tools (no Xcode), ad-hoc signed.
#   BUNDLE_ID=com.you.dozzledesk scripts/build-app.sh   # optional: your own bundle identifier
set -euo pipefail
BUNDLE_ID="${BUNDLE_ID:-io.github.dozzledesk.DozzleDesk}"
cd "$(dirname "$0")/.."
swift build -c release
APP=build/DozzleDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DozzleDesk "$APP/Contents/MacOS/DozzleDesk"
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
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
echo "built $APP ($BUNDLE_ID)"
