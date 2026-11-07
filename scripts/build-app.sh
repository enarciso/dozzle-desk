#!/usr/bin/env bash
# Builds build/DozzleDesk.app with only the Command Line Tools (no Xcode), ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/DozzleDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DozzleDesk "$APP/Contents/MacOS/DozzleDesk"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.narciso.dozzledesk</string>
  <key>CFBundleName</key><string>DozzleDesk</string>
  <key>CFBundleDisplayName</key><string>DozzleDesk</string>
  <key>CFBundleExecutable</key><string>DozzleDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>DozzleDesk connects to your Dozzle server on your local network to show homelab health.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
