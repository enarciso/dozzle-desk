#!/usr/bin/env bash
# Installs DozzleDesk.app into ~/Applications. Adds no login items or LaunchAgents.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
mkdir -p "$HOME/Applications"
pkill -TERM -x DozzleDesk 2>/dev/null && sleep 1 || true
rm -rf "$HOME/Applications/DozzleDesk.app"
ditto build/DozzleDesk.app "$HOME/Applications/DozzleDesk.app"
echo "installed ~/Applications/DozzleDesk.app — start it with: open ~/Applications/DozzleDesk.app"
