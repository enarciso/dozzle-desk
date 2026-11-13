<p align="center"><img src="Assets/icon-1024.png" width="160" alt="DozzleDesk icon"></p>

# DozzleDesk

A transparent, always-on container dashboard pinned to the macOS desktop, with a menu bar dropdown.
It's fed live by [Dozzle](https://github.com/amir20/dozzle)'s event stream (`/api/events/stream`).

DozzleDesk is an independent project. It isn't affiliated with or endorsed by Dozzle.

<p align="center">
  <img src="docs/card.png" width="440" alt="The DozzleDesk desktop card: three hosts with CPU sparklines, memory, disk and load; 17 running containers; a Needs attention list with an unhealthy and a restarting container; and the top containers by CPU and memory">
  &nbsp;
  <img src="docs/dropdown.png" width="380" alt="The menu bar dropdown: the same hosts, counts and Needs attention list, with Open Dozzle, Reconnect, options and Quit buttons">
</p>
<p align="center"><sub>The desktop card and the menu bar dropdown, showing a made-up demo homelab.</sub></p>

The desktop card sits just above the desktop icons and below every normal window, and appears on all
Spaces. It never takes focus and has no Dock icon.

**Menu bar item.** The icon turns orange when something needs attention and shows the problem count.
- **Left-click** opens a Control Center-style dropdown: status, host tiles, counts, "Needs attention",
  and buttons for Open Dozzle, Reconnect, options (Dozzle URL, desktop card) and Quit.
- **Right-click** (or Control-click) shows a classic menu with the same commands.

**Dropdown-only mode.** Turn off **Show Desktop Card** in the dropdown's options button or the
right-click menu. The card closes completely (it does no work while closed), and the choice is
remembered across launches. Launching DozzleDesk again while it's running opens the dropdown. If the
app has to close (Dozzle unreachable), the card briefly reappears with the closing message, so it never
vanishes silently. `--no-card` / `--card` override the saved choice for a single launch.

## Requirements
- macOS 14 or later, on Apple silicon or Intel.
- A Dozzle server **without authentication** (`DOZZLE_AUTH_PROVIDER=none`). DozzleDesk shows a clear
  message and exits if Dozzle asks for a login.
- To build from source: Swift 6 from the Xcode Command Line Tools (`xcode-select --install`). Xcode
  itself isn't needed.

## Download
1. Download `DozzleDesk-<version>.zip` from the
   [latest release](https://github.com/enarciso/dozzle-desk/releases/latest) and unzip it.
2. Move `DozzleDesk.app` to `Applications`.
3. Open it once past Gatekeeper (see below), then enter your Dozzle address.

**The app is not notarized.** It's ad-hoc signed, not signed with an Apple Developer ID, so macOS blocks
the first launch of a downloaded copy with "Apple could not verify DozzleDesk is free of malware".
To open it anyway, either:
- try to open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
- remove the download quarantine flag in Terminal:
  ```bash
  xattr -dr com.apple.quarantine /Applications/DozzleDesk.app
  ```

Releases are built by GitHub Actions from the tagged commit, not on anyone's laptop. GitHub signs a
provenance record for each zip. To check your download:
```bash
shasum -a 256 -c DozzleDesk-<version>.zip.sha256
gh attestation verify DozzleDesk-<version>.zip --repo enarciso/dozzle-desk
```
The second command needs the [GitHub CLI](https://cli.github.com). It confirms the zip came from
this repository's release workflow. Version 0.1.0 predates the workflow, so it has no provenance record.
If you'd rather not trust a prebuilt binary, build it yourself as below. It's the same code.

## Build from source
```bash
git clone https://github.com/enarciso/dozzle-desk.git && cd dozzle-desk
scripts/install.sh                     # builds and copies DozzleDesk.app to ~/Applications
open ~/Applications/DozzleDesk.app
```

Or run it straight from the checkout without installing:
```bash
swift build -c release && .build/release/DozzleDesk
```

### Connecting to your Dozzle
On first launch DozzleDesk asks for your Dozzle address: the URL you open Dozzle at in a browser,
such as `http://192.168.1.20:8080`, `dozzle.lan:8080` or `https://nas.lan/dozzle`. If you set
`DOZZLE_BASE`, include the base path.

It checks the address before saving it, and reports exactly what's wrong:
- the host can't be found, or it refused the connection,
- something answered that isn't Dozzle (wrong port, base path, or a login proxy in front of it),
- Dozzle requires login.

To change servers later, choose **Change Dozzle URL…** from the right-click menu or the dropdown's
options button. If the saved server is unreachable at launch, the closing message has a
**Change URL…** button.

Test an address from the terminal:
```bash
.build/release/DozzleDesk --check http://192.168.1.20:8080
```

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
| No Dozzle URL saved yet | Asks for one. Quitting that window exits cleanly |
| Dozzle unreachable at launch | "Can't reach …" with a **Change URL…** button for 8 s, then exits (code 0) |
| Connection drops (refused, reset, server restart) | Shows "Connection lost", dims the last data, retries after 3/6/12/24/30 s |
| Socket goes silent (half-open after a Wi-Fi drop) | After 25 s with no bytes it counts as lost (Dozzle pings every 20 s) |
| Still down after the grace period (2 min) | "Closing" for 3 s, then a clean exit (code 0). It does **not** relaunch itself |
| Dozzle comes back within the grace period | Goes live again and the grace timer resets |
| Mac sleeps | Disconnects deliberately; on wake it reconnects with a fresh grace window |
| Dozzle requires login (401/403) | Says so and exits; it never loops |

Quit, Ctrl-C, `kill` and logout all take the same teardown path: cancel tasks, close sockets, stop the
network monitor, remove observers, close the windows and status item, release the lock, exit 0.

## Options
These can be passed as flags, and the numeric ones can also be set with `defaults write`. Flags apply to that launch only.
- `--url URL`: use this Dozzle for this launch. The saved URL is unchanged.
- `--grace 120`: seconds to keep retrying before exiting.
- `--stall 25`: seconds of silence that count as a dead connection.
- `--opacity 1.0`: card opacity, 0.3–1.0.
- `--no-card` / `--card`: dropdown only, or show the card.
- `--check URL`: test an address, print the result and exit.

The settings domain is the app's bundle identifier, `io.github.dozzledesk.DozzleDesk`. When run
unbundled from `.build/`, it's `DozzleDesk`. For example:
```bash
defaults write io.github.dozzledesk.DozzleDesk grace -int 300
```

To build with your own identifier, run `BUNDLE_ID=com.you.dozzledesk scripts/build-app.sh`.

## Development
```bash
scripts/test.sh                       # unit tests (parser, reducer, connection policy, URL handling)
python3 scripts/fixture_server.py --port 9911 [--stall-after N] [--auth] [--demo]   # a fake Dozzle
.build/debug/DozzleDesk --url http://127.0.0.1:9911 --grace 20 --stall 6
```
`--demo` serves a fuller, made-up homelab. `scripts/screenshots.sh` uses it to regenerate the README
screenshots in `docs/`, so no real server or container names appear in them.
`scripts/make-icon.sh` redraws the app icon (`Assets/AppIcon.icns`) from `scripts/make-icon.swift`.
`scripts/test.sh` wraps `swift test` with the flags Swift Testing needs under the Command Line Tools.
`--render-png out.png [--render-when live|lost] [--render-delay 3] [--render-popover]` renders one
frame offscreen and exits.

### Releasing
Push a version tag. The [Release workflow](.github/workflows/release.yml) then runs the tests,
builds the universal app, attests its provenance, and creates a **draft** release with the zip and
checksum. Write what changed at the top of the draft, then publish it.
```bash
git tag -a v0.2.0 -m "DozzleDesk 0.2.0" && git push origin v0.2.0
```
To try a build without publishing anything, run the workflow by hand from the Actions tab. To build
the same zip locally, run `scripts/release.sh 0.2.0` (output goes to `dist/`).

## Uninstall
```bash
scripts/uninstall.sh                  # removes the app, its preferences and its support folder
```

## Safety notes
- **Read-only:** only GET requests to the Dozzle you configure. No actions, no shell, no telemetry.
- **Plain http is allowed.** Many homelab Dozzles have no TLS, so App Transport Security is relaxed.
  The only server the app ever contacts is the one you enter. Prefer `https://` when you have it.
- **Bounded resources:** about 1–2% CPU and a flat ~97 MB RSS against a 47-container, 4-host setup.
  Parsing runs off the main thread, the UI updates at most once a second, and updates pause while
  displays sleep.
- **Bounded memory:** each SSE line is capped at 8 MB (Dozzle's largest line is around 400 KB), and
  history uses fixed 60-point ring buffers.
- **Nothing system-level:** no sudo, entitlements, login items or LaunchAgents.
- **One instance at a time,** enforced with `flock` on `~/Library/Application Support/DozzleDesk/lock`.
- **Logs** go to Console.app:
  `log show --last 10m --predicate 'process == "DozzleDesk"'`

## License
[MIT](LICENSE). Dozzle is a separate project with its own license; DozzleDesk contains none of its code.
