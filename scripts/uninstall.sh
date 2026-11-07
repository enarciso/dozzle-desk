#!/usr/bin/env bash
# Removes everything DozzleDesk put on this Mac: the app, its preferences, its support folder.
set -uo pipefail
if pgrep -x DozzleDesk >/dev/null; then
  pkill -TERM -x DozzleDesk; sleep 2
  pgrep -x DozzleDesk >/dev/null && pkill -KILL -x DozzleDesk
fi
rm -rf "$HOME/Applications/DozzleDesk.app"
defaults delete com.narciso.dozzledesk 2>/dev/null || true   # bundled app
defaults delete DozzleDesk 2>/dev/null || true               # unbundled dev runs
rm -rf "$HOME/Library/Application Support/DozzleDesk"
echo "DozzleDesk removed."
