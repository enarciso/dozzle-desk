# DozzleDesk

A transparent, always-on homelab dashboard pinned to the macOS desktop, fed live by
[Dozzle](https://github.com/amir20/dozzle)'s event stream (`/api/events/stream`).

It sits just above the desktop icons, below every normal window, and appears on all Spaces.
It never takes focus and has no Dock icon.

**Menu bar item.** The icon turns orange when something needs attention and shows the problem count.
- **Left-click** opens a Control Center-style dropdown: status, host tiles, counts, "Needs attention",
  and buttons for Open Dozzle, Reconnect, card options (click-through, opacity, reset position) and Quit.
- **Right-click** (or Control-click) shows a classic menu with the same commands.

**Dropdown-only mode.** Turn off **Show Desktop Card** in the dropdown's options button or the
right-click menu. The card closes completely (it does no work while closed), and the choice is
remembered across launches. Launching DozzleDesk again while it's running opens the dropdown. If the
app has to close (Dozzle unreachable), the card briefly reappears with the closing message, so it never
vanishes silently. `--no-card` / `--card` override the saved choice for a single launch.

## What it shows
- **Host tiles:**
  - CPU % with a sparkline (summed container CPU ÷ cores)
  - memory used ÷ total
  - disk free
  - load average
  - running/total container counts
  - reachability
- **Container counts:** running, healthy, unhealthy, exited, paused.
- **Needs attention:**
  - unhealthy, dead or restarting containers
  - containers that exited or restarted in the last 10 minutes
  - hosts Dozzle can't reach
- **Top 5 containers** by CPU and by memory.

Click a host or container to open it in Dozzle. Drag the card to move it.

## Disconnect behaviour
| Situation | What happens |
|---|---|
| Dozzle unreachable at launch | "Can't reach …" for 5 s, then exits (code 0) |
| Connection drops (refused, reset, server restart) | Shows "Connection lost", dims the last data, retries after 3/6/12/24/30 s |
| Socket goes silent (half-open after a Wi-Fi drop) | After 25 s with no bytes it counts as lost (Dozzle pings every 20 s) |
| Still down after the grace period (2 min) | "Closing" for 3 s, then a clean exit (code 0). It does **not** relaunch itself |
| Dozzle comes back within the grace period | Goes live again and the grace timer resets |
| Mac sleeps | Disconnects deliberately; on wake it reconnects with a fresh grace window |
| Dozzle requires login (401/403) | Says so and exits; it never loops |

Quit, Ctrl-C, `kill` and logout all take the same teardown path: cancel tasks, close sockets, stop the
network monitor, remove observers, close the window and status item, release the lock, exit 0.

## Build and run (Command Line Tools only, no Xcode)
```bash
scripts/test.sh                       # 25 unit tests (parser, reducer, connection policy)
swift build -c release && .build/release/DozzleDesk            # run from the terminal
scripts/install.sh && open ~/Applications/DozzleDesk.app       # or install as an app
scripts/uninstall.sh                  # removes app, preferences, support folder
```

## Options
These can be passed as flags or set with `defaults write com.narciso.dozzledesk <key> <value>`:
- `--url` (default `http://narciso-linux:9900`)
- `--grace 120`
- `--stall 25`
- `--opacity 1.0`

Developer helpers:
- `--render-png out.png [--render-when live|lost] [--render-delay 3]` renders one frame offscreen and exits.
- `python3 scripts/fixture_server.py --port 9911 [--stall-after N] [--auth]` is a fake Dozzle for outage tests.

## Safety notes
- **Read-only:** only GET requests to Dozzle. No actions, no shell, no telemetry.
- **Bounded resources:** about 1–2% CPU and a flat ~97 MB RSS against a 47-container, 4-host lab. Parsing runs off the main thread, the UI updates at most once a second, and updates pause while displays sleep.
- **Bounded memory:** each SSE line is capped at 8 MB (Dozzle's largest line is about 400 KB), and history uses fixed 60-point ring buffers.
- **Nothing system-level:** no sudo, entitlements, login items or LaunchAgents.
- **One instance at a time,** enforced with `flock` on `~/Library/Application Support/DozzleDesk/lock`.
- **Logs** go to Console.app under subsystem `com.narciso.dozzledesk`:
  `log show --last 10m --predicate 'subsystem == "com.narciso.dozzledesk"'`
