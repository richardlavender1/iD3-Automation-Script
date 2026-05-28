# iD3 → LIMS Automation Pipeline

Unattended data export from the iD3 plate reader to LIMS via QuickSync + Google Drive. This README explains how the chain fits together so you can debug it when (not if) something breaks.

## Why this exists

Out of the box, the workflow needs a human at every step:

1. iD3 sends a plate result to QuickSync on the Script Runner PC.
2. QuickSync receives it silently — does nothing until a human right-clicks its tray icon and clicks "Open Last Result".
3. Even then, if the iD3 has been power-cycled at any point, QuickSync silently disconnects and a human has to manually re-link.

Molecular Devices have been asked to add auto-reconnect and auto-save — they declined. This pipeline removes both manual steps via an AutoHotkey watchdog and a scheduled robocopy.

## End-to-end flow

```
+----------+   network   +-----------+   tray menu   +-------------+   robocopy    +-------------+   GDrive   +------+
|   iD3    | ----------> | QuickSync | ------------> | Pickup folder| -----------> | GDrive sync | ---------> | LIMS |
| (plate)  |             | (tray app)|  click via    | (Excel files)|   every 2min | folder      |  cloud     |      |
+----------+             +-----------+   watchdog    +-------------+               +-------------+            +------+
```

Latency budget (typical worst case): plate finishes → file in Google Drive in ~3–4 minutes.

See "Cadence map" below for the per-stage breakdown.

## What lives where

| Component | Location | Purpose |
|---|---|---|
| QuickSync | `C:\Program Files (x86)\Molecular Devices\QuickSync\` | Vendor app, runs in tray, receives plate files from iD3 |
| QuickSync log | `C:\ProgramData\Molecular Devices\GimliData\logs\quickSync.log` | NLog file — watchdog tails this for disconnect events |
| Watchdog script | `C:\Users\<user>\quicksync-watchdog\quicksync-watchdog.ahk` | AutoHotkey v2 script doing the auto-reconnect + auto-save |
| Watchdog diagnostic log | `C:\Users\<user>\quicksync-watchdog\watchdog.log` | What the watchdog has been doing |
| Last-seen result state | `C:\Users\<user>\quicksync-watchdog\last_result.txt` | Persisted filename of the last result we processed — prevents duplicate-file spam |
| Pickup folder | (configured in QuickSync settings) | Where Excel files land after "Open Last Result" |
| Robocopy `.bat` | (configured in Task Scheduler) | Copies pickup-folder files to the Google Drive synced folder every 2 min |

All of this runs on the **Script Runner PC** (Win11). Auto-login is configured via Sysinternals Autologon so a reboot lands directly at the desktop without user interaction.

## What the watchdog does

The watchdog (`quicksync-watchdog.ahk`) has three independent jobs running concurrently:

### 1. Disconnect recovery (event-driven)
Tails the QuickSync log every 2s. When it sees `Connection was reset by the remote peer` (iD3 powered off), it:
- Waits for ICMP ping to come back (~30s after iD3 power-on)
- Waits for TCP port 8091 to accept connections (~5 min total iD3 boot time)
- Kills `QuickSync.exe` and `Gimli.DataService.exe`
- Relaunches QuickSync
- Waits for QuickSync's discovery log line
- Drives the tray menu via Win+B to re-link to the iD3

All waits are unbounded — iD3 can be off for a week, the watchdog just keeps waiting.

### 2. Connection-health heartbeat (60s timer)
Belt-and-braces for the case where QuickSync sits in a stale "connected" state without logging a disconnect. TCP-probes the iD3 every 60s. A down→up transition triggers the same recovery flow as above.

### 3. Result polling (20s timer)
QuickSync requires a manual click of "Open Last Result: \<name\>" to actually write the file to the pickup folder. The watchdog opens QuickSync's tray menu every 20s, reads the menu items via `GetMenuStringW`, extracts the current "Open Last Result" filename, and **only clicks if the filename differs from the last one we processed** (persisted to `last_result.txt`). This prevents duplicate file spam — each click timestamps a new file. After clicking, Excel launches briefly to write the pickup file, and the watchdog kills it.

### Dynamic tray icon lookup
The watchdog does **not** hardcode the QuickSync icon's position in the chevron flyout. It scans positions 1..15, opens each icon's context menu, and checks the menu contents (looking for "Add Service by IP" or "Available Services" — distinctive QuickSync items). The found position is cached for fast subsequent lookups; if the cache becomes wrong (Windows pushed a new icon in), the next scan finds and re-caches.

This is critical: a hardcoded position once caused the watchdog to send `Shift+F10 → End → Enter` into Google Drive's tray menu, which closed Google Drive entirely.

## Hotkeys (while the watchdog is running)

| Hotkey | What it does |
|---|---|
| Ctrl+Alt+R | Force a full recovery cycle (waits for iD3, kills+relaunches QuickSync, reconnects) |
| Ctrl+Alt+T | Test just the reconnect tray sequence (no kill/relaunch) — QS must be currently disconnected |
| Ctrl+Alt+P | Trigger one result-poll cycle manually |
| Ctrl+Alt+M | Diagnostic — dump QuickSync's current tray menu items to `watchdog.log` |
| Ctrl+Alt+Q | Quit the watchdog |

## Config knobs (top of the script)

| Knob | Current | What it gates |
|---|---|---|
| `IID3_IP` | `192.168.68.201` | iD3 IP address |
| `QUICKSYNC_EXE` | `C:\Program Files (x86)\Molecular Devices\QuickSync\QuickSync.exe` | QuickSync binary path |
| `QS_LOG_PATH` | `C:\ProgramData\Molecular Devices\GimliData\logs\quickSync.log` | QuickSync's NLog file |
| `LOG_POLL_MS` | 2000 | How often we re-read the QS log |
| `PING_RETRY_MS` | 5000 | Gap between ping attempts during recovery |
| `SERVICE_PORT` | 8091 | iD3 service port for TCP probing |
| `SERVICE_PROBE_MS` | 5000 | Gap between TCP probe attempts |
| `RESULT_POLL_MS` | 20000 | Result-polling cadence (most user-facing latency knob) |
| `EXCEL_KILL_DELAY_MS` | 5000 | How long we wait for Excel to write the pickup file before killing it |
| `CONNECTION_HEALTH_POLL_MS` | 60000 | TCP heartbeat cadence |
| `STARTUP_RECOVERY_DELAY_MS` | 30000 | Cold-boot grace period before triggering startup recovery |
| `MAX_TRAY_SCAN_POSITIONS` | 15 | How many chevron positions to scan when locating QuickSync |

## Cadence map (where the time goes per plate)

```
Plate finishes on iD3
   |
   v
QuickSync receives file              ~instant
   |
   v
RESULT_POLL_MS fires                 up to 20s
   |
   v
Menu read + click + Excel writes     ~3-5s
   |
   v
EXCEL_KILL_DELAY_MS                  5s
   |
   v
Robocopy task fires                  up to 2 min (Task Scheduler)
   |
   v
Google Drive Desktop sync            ~10-30s typical

```

## Setup from scratch

### One-time, per Script Runner PC

1. Install QuickSync from Molecular Devices' installer. Confirm it can manually connect to the iD3.
2. Configure QuickSync's pickup-folder location (the folder it dumps Excel files into when "Open Last Result" is clicked).
3. Install **AutoHotkey v2** from autohotkey.com (the watchdog uses v2 syntax, v1 will not parse it).
4. Copy `quicksync-watchdog.ahk` to `C:\Users\<script-runner-user>\quicksync-watchdog\`.
5. Set up **auto-login** for the script-runner user via Sysinternals Autologon (download from learn.microsoft.com/sysinternals).
6. Create a **Startup folder shortcut** for the watchdog: `Win+R` → `shell:startup` → New Shortcut → point to `quicksync-watchdog.ahk` → name it "QuickSync Watchdog".
7. Install **Google Drive for Desktop** and sign in with the lab account; verify the target sync folder is local on the PC.
8. Create the **robocopy scheduled task** in Task Scheduler:
   - Triggers: `At startup`, with "Repeat every 2 minutes for: Indefinitely"
   - Action: run your `.bat` that robocopies the pickup folder to the Google Drive sync folder
   - Security: "Run whether user is logged on or not", "Run with highest privileges"
   - Settings: "Stop task if it runs longer than 30 minutes", "Do not start a new instance", "If task fails, restart every 1 minute up to 3 times"
9. Reboot. Verify the chain by running a plate from the iD3 and watching it appear in Google Drive within ~4 min.

### Configuring LIMS to import from Google Drive

Out of scope of this document — see LIMS documentation.

## Troubleshooting

**No files showing up in Google Drive after a plate.**

Walk the chain from the iD3 end:

1. Did QuickSync receive the file? Check Task Manager — `QuickSync.exe` running? If not, the watchdog should have restarted it; check `watchdog.log` for recovery activity.
2. Did the result poll click "Open Last Result"? `watchdog.log` should have a line like `Result poll: NEW result 'foo' (previous: 'bar') — clicking`. If the previous filename equals the new filename, the click was suppressed — delete `last_result.txt` to force a re-click.
3. Did the pickup folder get an Excel file? Look in the folder configured in QuickSync settings. If empty, the click didn't fire — check `watchdog.log` for `ERROR: context menu opened is NOT QuickSync's` (icon position drifted; restart the watchdog to force a fresh scan).
4. Did robocopy run? Task Scheduler → your task → History tab → "Last Run Time" should be recent. "Last Run Result" should be `(0x0)`.
5. Did Google Drive sync? The Google Drive Desktop icon's tooltip will say "All caught up" or show pending uploads.
6. Did LIMS pick it up? LIMS-side problem.

**Watchdog isn't running on boot.**

- Verify the Startup folder shortcut exists: `Win+R` → `shell:startup` → look for "QuickSync Watchdog".
- Verify auto-login is configured: reboot and confirm the PC lands at the desktop without prompting for credentials.
- Look for AutoHotkey error popups that might have been dismissed.

**Watchdog is running but not reacting to a power-cycle.**

- Check `watchdog.log` for `Connection was reset` lines and recovery activity.
- If the watchdog log is silent, the QuickSync log may not be where we think — verify `QS_LOG_PATH`.
- The TCP heartbeat (every 60s) provides a backup detector; if neither path catches a disconnect, ping the iD3 manually and check whether QuickSync.exe is even running.

**Excel files in the pickup folder are duplicating.**

- The smart-polling filename gate should prevent this. If you see duplicates, check that `last_result.txt` is being written (file should exist alongside the .ahk; its contents should be the most recent filename QS saw).
- If the file is missing or empty, `SaveLastResult` is failing silently — check file permissions on the watchdog directory.

**Tray automation hits the wrong app's menu** (e.g. Google Drive quits unexpectedly).

- Should not happen — the dynamic icon finder + `IsQuickSyncMenuOpen` guard catches this. If it does, check `watchdog.log` for `ERROR: context menu opened is NOT QuickSync's` lines.
- If the guard isn't catching it, QuickSync's menu identification keywords may need updating. Open `IsQuickSyncMenuOpen()` and update the substrings ("Add Service by IP", "Available Services") to match the current QS menu.

## Known limitations

- The whole chain depends on a logged-in desktop session for the AutoHotkey tray automation. The watchdog cannot drive Win+B from a locked or non-existent user session, so auto-login is mandatory.
- The dynamic icon finder scans up to 15 chevron-flyout positions. If QuickSync ends up beyond position 15, raise `MAX_TRAY_SCAN_POSITIONS`.
- Smart polling assumes QuickSync's context menu has at least one of "Add Service by IP" or "Available Services" as a distinguishing item. If a future QS update renames these, the icon identification will break — update `IsQuickSyncMenuOpen()` accordingly.
- The watchdog handles a single iD3. Multi-instrument setups would need extending `IID3_IP` to a list and tracking per-instrument state.
- Google Drive sync latency is outside this script's control. If LIMS needs sub-minute file delivery, replace Google Drive with a direct SMB share or similar.

## Maintenance

- Updating the watchdog: edit the `.ahk` in place, right-click the green H tray icon → Reload Script. No reboot needed.
- Updating the robocopy `.bat`: edit it; the scheduled task picks up changes on the next 2-minute tick.
- Updating QuickSync (vendor): keep an eye out for an auto-reconnect / auto-export feature — if either appears, large chunks of this pipeline can be retired.
