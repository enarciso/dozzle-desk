#!/usr/bin/env bash
# Removes everything DozzleDesk put on this Mac: the app, its preferences, its support folder.
#   BUNDLE_ID=com.you.dozzledesk scripts/uninstall.sh   # if you built with your own bundle identifier
set -uo pipefail
BUNDLE_ID="${BUNDLE_ID:-io.github.dozzledesk.DozzleDesk}"
if pgrep -x DozzleDesk >/dev/null; then
  pkill -TERM -x DozzleDesk; sleep 2
  pgrep -x DozzleDesk >/dev/null && pkill -KILL -x DozzleDesk
fi
rm -rf "$HOME/Applications/DozzleDesk.app"
defaults delete "$BUNDLE_ID" 2>/dev/null || true             # bundled app
defaults delete DozzleDesk 2>/dev/null || true               # unbundled runs
rm -rf "$HOME/Library/Application Support/DozzleDesk"
echo "DozzleDesk removed."
