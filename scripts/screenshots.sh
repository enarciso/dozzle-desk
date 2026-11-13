#!/usr/bin/env bash
# Regenerates the README screenshots (docs/card.png, docs/dropdown.png) from the made-up demo
# homelab in fixture_server.py, so no real server, hostname or container appears in them.
#   scripts/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-9951}"
DELAY="${DELAY:-90}"   # seconds of live data before rendering, so the sparklines fill in
swift build
python3 scripts/fixture_server.py --port "$PORT" --demo >/dev/null 2>&1 &
FIXTURE=$!
trap 'kill $FIXTURE 2>/dev/null || true' EXIT
sleep 1
mkdir -p docs
URL="http://127.0.0.1:$PORT"
.build/debug/DozzleDesk --url "$URL" --render-png docs/card.png --render-delay "$DELAY" &
CARD=$!
.build/debug/DozzleDesk --url "$URL" --render-png docs/dropdown.png --render-delay "$DELAY" --render-popover
wait "$CARD"
