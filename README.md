# macbook-ha-bridge

Tiny macOS daemon that pushes a MacBook's state to a Home Assistant REST API. Two entities:

- `sensor.<prefix>_active_display` — name of the active display (where the menu bar lives). E.g. `Built-in`, `LG HDR 4K`.
- `binary_sensor.<prefix>_locked` — `on` when the screen is locked, `off` otherwise.

Single binary, two modes:

- **GUI** (no args): when the user opens the .app from Finder, a window shows install/running/stopped status and offers Install/Reinstall/Uninstall.
- **Daemon** (`--daemon` arg): launchd runs the same binary headless, polls every 2 s, pushes to HA. No dock icon.

Lives entirely in user-space — no `sudo`, no system-wide changes:

| File | Purpose |
|---|---|
| `~/.local/bin/macbook-ha-bridge` *or* `/Applications/macbook-ha-bridge.app/Contents/MacOS/macbook-ha-bridge` | The binary |
| `~/Library/LaunchAgents/cz.lnrt.macbook-ha-bridge.plist` | launchd autostart |
| `~/.config/macbook-ha-bridge/config.json` | Config (HA URL, token, prefix, device name) |
| `~/Library/Logs/macbook-ha-bridge.log` | Log |

## Distribution

Two delivery paths:

### 1. `.dmg` (recommended for end users)

Build with `./build-app.sh`. Outputs `~/Downloads/macbook-ha-bridge.dmg` (~3 MB):

- Universal binary (`arm64` + `x86_64`)
- Bundled `AppIcon.icns` derived from `logo.jpg`
- Custom Finder layout with arrow → Applications + readme
- Ad-hoc codesigned (no Apple Developer ID — recipient does Ctrl+click → Open on first launch)

End-user flow:

1. Mount the DMG.
2. Drag `macbook-ha-bridge.app` to `Applications`.
3. Open it. GUI opens with `● Not installed`. Click **Install…**.
4. Fill HA URL + Long-Lived Access Token + entity prefix + device name.
5. **Save & Install** writes the config, generates the launchd plist (pointed at the binary inside the .app), bootstraps the agent, kickstarts once for clean network init, and verifies the entity appears in HA.

The agent restarts at every login. Re-opening the .app shows current status; closing the window quits the GUI but the daemon keeps running.

### 2. `install.sh` (for developers / CLI users)

Legacy shell flow:

```bash
cp config.example.json config.json   # then edit values
./install.sh
```

Compiles via `swiftc`, copies the binary to `~/.local/bin/`, templates the plist, loads the agent.

## Source layout

| File | Purpose |
|---|---|
| `main.swift` | Single-file Swift source, both GUI and daemon modes |
| `build-app.sh` | Build universal .app bundle + DMG with Finder layout |
| `mask-squircle.swift` | One-shot helper: clip an image to a squircle, produce transparent-corner PNG (for the `.icns`) |
| `make-dmg-bg.swift` | One-shot helper: render the DMG's background image (gradient + arrow + text) |
| `install.sh` | Legacy CLI installer (no .app) |
| `cz.lnrt.macbook-ha-bridge.plist` | launchd plist template (used by `install.sh`; the .app generates its own at install time) |
| `config.example.json` | Config template — copy to `config.json` and fill |
| `logo.jpg` | 1024×1024 source logo (squircle artwork on checker — masked to PNG at build time) |
| `installation.md` | Verbose end-user install guide for the CLI flow |

`config.json` is **not** in the repo — it contains a real Home Assistant token. Use `config.example.json` as a template.

## Detection details

- **Active display**: `CGMainDisplayID()`. If it's the built-in panel, returns `Built-in`. Otherwise looks up the matching `NSScreen` and returns its `localizedName`.
- **Lock state**: `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`. No special permissions required.
- **Sleep / wake**: `NSWorkspace.willSleepNotification` / `didWakeNotification`. On `willSleep` the daemon force-pushes `locked=true` so HA sees the lock immediately rather than after wake.

## Push cadence

- Polling: `pollInterval` seconds (default 2.0). State is compared against the last pushed state.
- If state changed → push immediately.
- Otherwise, if `heartbeatInterval` seconds elapsed since the last push (default 60), push anyway. This keeps `last_updated` in HA fresh so a long-stale entity can be detected as "MacBook offline".
