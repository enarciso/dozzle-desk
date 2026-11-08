#!/usr/bin/env bash
# Regenerates Assets/AppIcon.icns and Assets/icon-1024.png from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/make-icon.swift Assets
iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
rm -r Assets/AppIcon.iconset
echo "wrote Assets/AppIcon.icns"
