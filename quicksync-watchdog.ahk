#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir
Persistent

; ==============================================================
;  QuickSync Watchdog — auto-reconnect after iD3 power cycle
; ==============================================================
;  Watches the QuickSync NLog file for a disconnect, waits for
;  the iD3 to come back online (ping), restarts QuickSync, then
;  drives the tray menu to reconnect.
;
;  Hotkeys (while running):
;    Ctrl+Alt+R   force a recovery cycle (for testing)
;    Ctrl+Alt+T   try the tray-click sequence only (for tuning)
;    Ctrl+Alt+P   trigger one result-poll cycle
;    Ctrl+Alt+M   dump the QuickSync tray menu items to the log
;    Ctrl+Alt+S   send a test Slack ping (verify the webhook)
;    Ctrl+Alt+Q   quit the watchdog
; ==============================================================

; ---------------- CONFIG --------------------------------------
IID3_IP             := "192.168.68.201"
QUICKSYNC_EXE       := "C:\Program Files (x86)\Molecular Devices\QuickSync\QuickSync.exe"
QS_LOG_PATH         := "C:\ProgramData\Molecular Devices\GimliData\logs\quickSync.log"
WATCHDOG_LOG        := A_ScriptDir . "\watchdog.log"
LOG_POLL_MS         := 2000           ; how often we re-read the QS log
PING_RETRY_MS       := 5000           ; gap between ping attempts during recovery
; ICMP comes back within ~30s of power-on, but the iD3 service port doesn't
; accept connections until ~5 minutes later. We MUST wait for the service port
; before killing QuickSync — otherwise discovery runs on a half-booted device.
; The iD3 can be powered off for days or weeks at a time, so all waits below
; are unbounded and just log a heartbeat every HEARTBEAT_LOG_S so you can see
; the watchdog is alive.
SERVICE_PORT        := 8091           ; iD3 SpectraMax_iDx service (from log)
SERVICE_PROBE_MS    := 5000           ; gap between TCP probe attempts
POST_DISCOVERY_PAUSE_MS := 2500       ; let the tray icon + "ready" popup settle
; Cold-boot grace: at user login the keyboard hook / tray / focus aren't stable
; for the first ~30s. Wait before triggering startup recovery so Win+B doesn't
; race with login-time popups.
STARTUP_RECOVERY_DELAY_MS := 30000

; --- Result polling ---
; QuickSync receives plate-read files silently — they're only written to the
; "pickup" location when the user clicks "Open Last Result: <name>" in the tray.
; We periodically drive the tray menu to do that click. End jumps to the last
; menu item — which is "Open Last Result" when a result is waiting, and the
; harmless "Available Services" submenu opener when not.
RESULT_POLL_MS         := 20000        ; check for a new result every 20s
EXCEL_KILL_DELAY_MS    := 5000         ; let Excel save the file before killing
ENABLE_RESULT_POLLING  := true         ; smart polling enabled — only clicks when filename changes
LAST_RESULT_FILE       := A_ScriptDir . "\last_result.txt"  ; persisted last-seen filename

; --- Connection-health heartbeat ---
; Belt-and-braces for the case where QuickSync sits in a stale "connected"
; state — e.g. it was connected when the iD3 was already off, so no disconnect
; line ever appeared in the log. Every N seconds we TCP-probe the iD3 and
; track reachability. A down→up transition (iD3 came back online while QS
; was unaware) is treated the same as a fresh disconnect: trigger recovery.
CONNECTION_HEALTH_POLL_MS := 60000     ; reachability poll cadence

; --- Idle heartbeat ---
; While idle (WATCHING phase) the log would otherwise be silent for long
; stretches. Every HEARTBEAT_LOG_MS we write ONE snapshot line so the timeline
; has no unexplained gaps — if a plate was run at 11:00 and nothing active shows,
; the nearby heartbeat ("idle, iD3 reachable, no result seen") tells you the
; plate never reached the tool. Doubles as the rate limit for poll-issue logging.
HEARTBEAT_LOG_MS := 300000             ; idle WATCHING snapshot cadence (5 min)

; --- Tray navigation (hardcoded position) ---
; Number of Right arrows from the start of the chevron flyout (which is
; position 1 = H/watchdog) to reach QuickSync's icon. Adjust if QS lands
; somewhere else in the flyout. If wrong, the menu-content verification
; in OpenQuickSyncContextMenu will catch it before any harmful clicks.
TRAY_RIGHT_ARROWS_IN_FLYOUT := 2

; --- QuickSync context-menu navigation ---
; The menu order is: About / Close / Add Service by IP / Available Services
; → submenu of discovered devices. After Shift+F10 opens the menu we send
; N Down presses to reach "Available Services", then Right to open it,
; then M Down presses to highlight the iD3.
MENU_DOWNS_TO_AVAILABLE_SERVICES := 4
SUBMENU_DOWNS_TO_DEVICE          := 1

; --- Slack notifications (direct message, status-change only) ---
; The watchdog DMs you ONLY when the pipeline status changes — OK -> recovering
; -> iD3 down -> export failing -> back to OK — so you're never spammed by a ping
; per plate or a ping every retry. A stuck plate or an ongoing recovery pings
; once. It runs on the unattended automation PC, so it can't use a desktop Slack
; app — it calls the Slack Web API (chat.postMessage) with a bot token. Setup:
;   1. Create a Slack app at api.slack.com/apps ("From scratch"), in your workspace.
;   2. OAuth & Permissions -> Bot Token Scopes: add  chat:write  and  im:write
;   3. Install to Workspace; copy the "Bot User OAuth Token" (starts with xoxb-).
;   4. Paste it into SLACK_BOT_TOKEN below.
; SLACK_DM_USER_ID is your Slack member ID (already filled in). Leave the token
; "" to disable Slack entirely. Test the wiring with Ctrl+Alt+S.
; NOTE: the token is a secret — keep this .ahk off any shared/public location.
SLACK_BOT_TOKEN        := ""              ; xoxb-... ; "" = Slack off
SLACK_DM_USER_ID       := "U0AJNQUS4SU"   ; Richard's Slack member ID (DM target)
; ---------------- end CONFIG ----------------------------------

DISCONNECT_PATTERNS := [
    "Connection was reset by the remote peer",
    "Tried to associate with unreachable remote address"
]
DISCOVERY_OK_PATTERN := "Service Discovery finished\. Services found: [1-9]"

; ---------------- STATE ---------------------------------------
global LogPosition        := 0     ; bytes we've already consumed from QS log
global Recovering         := false ; guard against re-entering recovery mid-flight
global LastResultSeen     := ""    ; last "Open Last Result: <name>" we processed
global LastReachable      := true  ; last TCP probe result for the iD3 service port

; --- Phase tracking (drives the phase tag + begin/end banners in the log) ---
global CurrentPhase       := "STARTUP"   ; tag prefixed to every WatchdogLog line
global PrevPhase          := "WATCHING"  ; phase to restore to when the active one ends
global PhaseStartTick     := 0           ; A_TickCount when the active phase began
global PhaseStartStamp    := ""          ; wall-clock stamp when the active phase began
global LastPollIssueTick  := 0           ; rate-limits "couldn't open menu" style notes
global CurrentStatus      := ""          ; last Slack-reported pipeline status; DM only on change

; ---------------- ENTRY ---------------------------------------
PhaseStartTick := A_TickCount
PhaseStartStamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
WatchdogRaw("===== STARTUP begin =====")
WatchdogLog("=== watchdog starting ===")
WatchdogLog("Target iD3: " . IID3_IP)
WatchdogLog("QS log path: " . QS_LOG_PATH)
InitialiseLogPosition()
LoadLastResult()
; If QuickSync isn't already running on startup, run a recovery cycle so we
; reach a known-good state (waits for iD3 if needed, then launches + connects).
; If QuickSync IS running, we assume it's healthy and rely on log-tailing to
; catch any future disconnect. Use Ctrl+Alt+R to force recovery on demand.
if (!ProcessExist("QuickSync.exe")) {
    WatchdogLog("QuickSync.exe not running on startup → triggering recovery in " . (STARTUP_RECOVERY_DELAY_MS // 1000) . "s")
    SetTimer(() => RecoverFromDisconnect(), -STARTUP_RECOVERY_DELAY_MS)
}
SetTimer(PollLog, LOG_POLL_MS)
if (ENABLE_RESULT_POLLING) {
    WatchdogLog("Result polling enabled — every " . (RESULT_POLL_MS // 1000) . "s")
    SetTimer(PollForNewResult, RESULT_POLL_MS)
}
SetTimer(CheckConnectionHealth, CONNECTION_HEALTH_POLL_MS)
SetTimer(Heartbeat, HEARTBEAT_LOG_MS)
; Startup complete — close the STARTUP banner and settle into the WATCHING phase.
PhaseEnd()
SetStatus("OK", "QuickSync watchdog started on " . A_ComputerName . " — status OK")
return

^!r:: {
    WatchdogLog("Manual recovery triggered via hotkey")
    RecoverFromDisconnect()
}
^!t:: {
    WatchdogLog("Manual tray-click test triggered via hotkey")
    OpenQuickSyncTrayMenuAndConnect()
}
^!p:: {
    WatchdogLog("Manual result-poll triggered via hotkey")
    PollForNewResult()
}
^!m:: {
    WatchdogLog("--- Menu read diagnostic ---")
    DumpQuickSyncMenuItems()
    WatchdogLog("--- Menu read diagnostic end ---")
}
^!s:: {
    WatchdogLog("Manual Slack test triggered via hotkey")
    SlackNotify("Test ping from QuickSync watchdog on " . A_ComputerName)
}
^!q:: {
    WatchdogLog("=== watchdog stopping (hotkey) ===")
    ExitApp
}

; ==============================================================
;  Log tailing
; ==============================================================
InitialiseLogPosition() {
    global LogPosition, QS_LOG_PATH
    try {
        file := FileOpen(QS_LOG_PATH, "r")
        if (file) {
            LogPosition := file.Length
            file.Close()
            WatchdogLog("Initial log position: " . LogPosition . " bytes")
        }
    } catch as e {
        WatchdogLog("WARN: could not open QS log on startup: " . e.Message)
        LogPosition := 0
    }
}

PollLog() {
    global LogPosition, QS_LOG_PATH, DISCONNECT_PATTERNS, Recovering
    if (Recovering)
        return
    try {
        file := FileOpen(QS_LOG_PATH, "r")
        if (!file)
            return
        currentLen := file.Length
        if (currentLen < LogPosition) {
            ; file shrunk → rotated; reset to start
            WatchdogLog("Log rotation detected, resetting position")
            LogPosition := 0
        }
        if (currentLen = LogPosition) {
            file.Close()
            return
        }
        file.Pos := LogPosition
        chunk := file.Read(currentLen - LogPosition)
        LogPosition := currentLen
        file.Close()

        for pattern in DISCONNECT_PATTERNS {
            if (InStr(chunk, pattern)) {
                WatchdogLog("Disconnect pattern matched: " . pattern)
                RecoverFromDisconnect()
                return
            }
        }
    } catch as e {
        WatchdogLog("WARN: log poll error: " . e.Message)
    }
}

; ==============================================================
;  Recovery state machine
; ==============================================================
RecoverFromDisconnect() {
    global Recovering, IID3_IP, SERVICE_PORT, QUICKSYNC_EXE
    if (Recovering)
        return
    Recovering := true
    PhaseBegin("RECOVERY")
    SetStatus("RECOVERING", "iD3 connection lost — recovering on " . A_ComputerName . "...")
    launchFailed := false
    try {
        WaitForPing(IID3_IP)
        WaitForServicePort(IID3_IP, SERVICE_PORT)
        KillProcess("QuickSync.exe")
        KillProcess("Gimli.DataService.exe")
        Sleep 1500
        WatchdogLog("Relaunching QuickSync: " . QUICKSYNC_EXE)
        SplitPath QUICKSYNC_EXE, , &qsDir
        try {
            Run QUICKSYNC_EXE, qsDir
        } catch as e {
            WatchdogLog("ERROR: could not launch QuickSync: " . e.Message)
            launchFailed := true
            SetStatus("RECOVERY_FAILED", ":warning: Recovery could NOT launch QuickSync on " . A_ComputerName . ": " . e.Message)
            return
        }
        WaitForDiscovery()
        Sleep POST_DISCOVERY_PAUSE_MS
        OpenQuickSyncTrayMenuAndConnect()
    } finally {
        dur := PhaseEnd()
        if (!launchFailed)
            SetStatus("OK", "Recovered on " . A_ComputerName . " after " . dur . " — back to OK")
        Recovering := false
    }
}

WaitForPing(ip) {
    global PING_RETRY_MS
    WatchdogLog("Wait: pinging " . ip . " every " . (PING_RETRY_MS // 1000) . "s …")
    startTick := A_TickCount
    cycles := 0
    Loop {
        cycles++
        if (PingHost(ip)) {
            WatchdogLog(Format("Wait: ping OK after {1} ({2} probes)", FormatDuration((A_TickCount - startTick) // 1000), cycles))
            return
        }
        Sleep PING_RETRY_MS
    }
}

WaitForServicePort(ip, port) {
    global SERVICE_PROBE_MS
    WatchdogLog("Wait: TCP probing " . ip . ":" . port . " every " . (SERVICE_PROBE_MS // 1000) . "s (iD3 service boot) …")
    startTick := A_TickCount
    cycles := 0
    Loop {
        cycles++
        if (TcpProbe(ip, port)) {
            WatchdogLog(Format("Wait: service port {1} open after {2} ({3} probes)", port, FormatDuration((A_TickCount - startTick) // 1000), cycles))
            return
        }
        Sleep SERVICE_PROBE_MS
    }
}

PingHost(ip) {
    ; Returns true if a single ICMP echo succeeded.
    cmd := A_ComSpec . ' /c ping.exe -n 1 -w 2000 ' . ip . ' | findstr /C:"TTL="'
    return (RunWaitHidden(cmd) = 0)
}

TcpProbe(ip, port) {
    ; Returns true if a TCP connection to ip:port succeeds within 2s.
    psCmd := "$c=New-Object Net.Sockets.TcpClient;try{$ar=$c.BeginConnect('" . ip . "'," . port . ",$null,$null);if($ar.AsyncWaitHandle.WaitOne(2000,$false)){$c.EndConnect($ar);exit 0}else{exit 1}}catch{exit 1}finally{$c.Close()}"
    cmd := 'powershell.exe -NoProfile -Command "' . psCmd . '"'
    return (RunWaitHidden(cmd) = 0)
}

WaitForDiscovery() {
    global LogPosition, QS_LOG_PATH, DISCOVERY_OK_PATTERN, IID3_IP
    WatchdogLog("Wait: QuickSync to discover iD3 (tailing QS log) …")
    startTick := A_TickCount
    cycles := 0
    foundOurIP := false
    Loop {
        cycles++
        Sleep 1000
        try {
            file := FileOpen(QS_LOG_PATH, "r")
            if (file) {
                currentLen := file.Length
                if (currentLen > LogPosition) {
                    file.Pos := LogPosition
                    chunk := file.Read(currentLen - LogPosition)
                    LogPosition := currentLen
                    if (InStr(chunk, IID3_IP))
                        foundOurIP := true
                    if (foundOurIP && RegExMatch(chunk, DISCOVERY_OK_PATTERN)) {
                        file.Close()
                        WatchdogLog(Format("Wait: discovery confirmed after {1} ({2} log polls)", FormatDuration((A_TickCount - startTick) // 1000), cycles))
                        return
                    }
                }
                file.Close()
            }
        } catch as e {
            WatchdogLog("WARN: discovery poll error: " . e.Message)
        }
    }
}

FormatDuration(totalSeconds) {
    h := totalSeconds // 3600
    m := (totalSeconds // 60) - (h * 60)
    s := Mod(totalSeconds, 60)
    if (h > 0)
        return Format("{1}h{2:02}m{3:02}s", h, m, s)
    if (m > 0)
        return Format("{1}m{2:02}s", m, s)
    return Format("{1}s", s)
}

; ==============================================================
;  Process control
; ==============================================================
KillProcess(exeName) {
    if (ProcessExist(exeName)) {
        WatchdogLog("Killing " . exeName)
        try {
            ProcessClose(exeName)
        } catch {
        }
        ; Hard kill as a fallback
        RunWaitHidden(A_ComSpec . ' /c taskkill /F /IM "' . exeName . '" /T')
        ProcessWaitClose(exeName, 5)
    } else {
        WatchdogLog(exeName . " not running, skipping kill")
    }
}

RunWaitHidden(cmd) {
    ; Returns the exit code, runs hidden.
    return RunWait(cmd, , "Hide")
}

; ==============================================================
;  Menu identity check — is the currently-open #32768 popup ours?
; ==============================================================
; SAFETY GUARD. The tray icon's position in the chevron flyout can drift
; (icons re-register at different positions). Without this check, hitting
; the wrong icon by one slot causes us to send `Shift+F10 → End → Enter`
; into someone else's tray menu — which has previously closed Google Drive,
; among other side effects. Always confirm the open menu is QuickSync's
; before driving it.
IsQuickSyncMenuOpen() {
    hWnd := WinExist("ahk_class #32768")
    if (!hWnd)
        return false
    ; 500ms timeout (default is 5s); a sluggish app's menu shouldn't block our scan
    try {
        hMenu := SendMessage(0x01E1, 0, 0, , "ahk_id " . hWnd, , , , 500)
    } catch {
        return false
    }
    if (!hMenu)
        return false
    count := DllCall("GetMenuItemCount", "Ptr", hMenu, "Int")
    if (count < 4)
        return false
    Loop count {
        idx := A_Index - 1
        len := DllCall("GetMenuStringW", "Ptr", hMenu, "UInt", idx, "Ptr", 0, "Int", 0, "UInt", 0x0400, "Int")
        if (len <= 0)
            continue
        buf := Buffer((len + 1) * 2, 0)
        DllCall("GetMenuStringW", "Ptr", hMenu, "UInt", idx, "Ptr", buf, "Int", len + 1, "UInt", 0x0400)
        text := StrGet(buf, "UTF-16")
        if (SubStr(text, 1, 1) = "&")
            text := SubStr(text, 2)
        ; "Add Service by IP" is the most distinctive QS-specific item.
        ; "Available Services" is a backup.
        if (InStr(text, "Add Service by IP", false) || InStr(text, "Available Services", false))
            return true
    }
    return false
}

; ==============================================================
;  Tray icon → context menu (hardcoded position)
; ==============================================================
; Opens chevron flyout, walks `TRAY_RIGHT_ARROWS_IN_FLYOUT` Right arrows
; to reach QuickSync's icon, opens its context menu, verifies the menu
; really is QS's (the IsQuickSyncMenuOpen guardrail catches landing on
; the wrong app's tray icon — preventing e.g. accidentally closing
; Google Drive if the position drifts).
; Returns true with QS's context menu open (caller must Esc it), or
; false if the flyout couldn't open or the menu at that position isn't
; QuickSync's.
OpenQuickSyncContextMenu() {
    global TRAY_RIGHT_ARROWS_IN_FLYOUT
    if (!OpenChevronFlyoutWithRetries()) {
        WatchdogLog("OpenQS: could not open chevron flyout")
        return false
    }
    Loop TRAY_RIGHT_ARROWS_IN_FLYOUT {
        Send "{Right}"
        Sleep 120
    }
    Sleep 150
    Send "+{F10}"
    Sleep 500
    if (IsQuickSyncMenuOpen())
        return true
    WatchdogLog("OpenQS: menu at position " . (TRAY_RIGHT_ARROWS_IN_FLYOUT + 1) . " is NOT QuickSync's — aborting (check TRAY_RIGHT_ARROWS_IN_FLYOUT)")
    Send "{Esc}"
    Sleep 200
    Send "{Esc}"
    Sleep 200
    return false
}

; ==============================================================
;  Menu reading — read the QS tray context menu items by text
; ==============================================================
; Reads items from a #32768 popup menu that is ALREADY OPEN. Does NOT open
; or close the menu — callers manage the menu lifecycle themselves.
; Returns an array of strings, or [] if the menu couldn't be read.
ReadOpenMenuItems() {
    items := []
    hWnd := WinExist("ahk_class #32768")
    if (!hWnd)
        return items
    hMenu := SendMessage(0x01E1, 0, 0, , "ahk_id " . hWnd)
    if (!hMenu)
        return items
    count := DllCall("GetMenuItemCount", "Ptr", hMenu, "Int")
    Loop count {
        idx := A_Index - 1
        len := DllCall("GetMenuStringW", "Ptr", hMenu, "UInt", idx, "Ptr", 0, "Int", 0, "UInt", 0x0400, "Int")
        if (len <= 0) {
            items.Push("")
            continue
        }
        buf := Buffer((len + 1) * 2, 0)
        DllCall("GetMenuStringW", "Ptr", hMenu, "UInt", idx, "Ptr", buf, "Int", len + 1, "UInt", 0x0400)
        items.Push(StrGet(buf, "UTF-16"))
    }
    return items
}

; Opens the QS tray menu (via dynamic icon finder), reads items, closes it.
; Returns an array of strings, or [] if the menu wasn't readable.
ReadQuickSyncMenuItems() {
    if (!OpenQuickSyncContextMenu()) {
        WatchdogLog("ReadMenu: could not open QuickSync context menu")
        return []
    }
    items := ReadOpenMenuItems()
    Send "{Esc}"
    Sleep 200
    Send "{Esc}"
    return items
}

DumpQuickSyncMenuItems() {
    items := ReadQuickSyncMenuItems()
    if (items.Length = 0) {
        WatchdogLog("ReadMenu: no items returned")
        return
    }
    for i, t in items
        WatchdogLog("    [" . i . "] '" . t . "'")
}

; ==============================================================
;  Connection-health heartbeat
; ==============================================================
; Detects the case where QS thinks it's connected but the iD3 was actually
; unreachable at handshake time. We TCP-probe the iD3 periodically; a
; down→up transition triggers the same recovery flow as a logged disconnect.
CheckConnectionHealth() {
    global Recovering, LastReachable, IID3_IP, SERVICE_PORT
    if (Recovering)
        return
    nowReachable := TcpProbe(IID3_IP, SERVICE_PORT)
    if (nowReachable && !LastReachable) {
        WatchdogRaw("[HEALTH] iD3 came back online (down->up) — triggering recovery")
        LastReachable := true
        RecoverFromDisconnect()   ; this flips status to RECOVERING (one DM)
        return
    }
    if (!nowReachable && LastReachable) {
        WatchdogRaw("[HEALTH] iD3 became unreachable (up->down) — waiting for it to return")
        SetStatus("iD3_DOWN", ":warning: iD3 unreachable on " . A_ComputerName . " — waiting for it to return")
        LastReachable := false
        return
    }
    ; No transition. Don't log every tick to avoid log spam.
}

; ==============================================================
;  Result polling — filename-aware
; ==============================================================
;  Reads the QS tray menu, finds "Open Last Result: <name>", and only clicks
;  it when <name> is different from what we saw last time (persisted to disk
;  so it survives watchdog restarts). Each click of the menu item produces a
;  new timestamped Excel file in the pickup folder, so blind polling would
;  dupe the same plate read every tick — hence the filename gate.
PollForNewResult() {
    global Recovering, LastResultSeen, EXCEL_KILL_DELAY_MS
    if (Recovering)
        return
    if (!ProcessExist("QuickSync.exe"))
        return

    ; Open QS context menu ONCE — we read items in-place and navigate by
    ; index without ever closing the menu between the read and the click.
    if (!OpenQuickSyncContextMenu()) {
        LogPollIssue("couldn't open the QuickSync tray menu (will keep trying)")
        return
    }
    items := ReadOpenMenuItems()
    if (items.Length = 0) {
        LogPollIssue("QuickSync tray menu opened but no items were readable (will keep trying)")
        Send "{Esc}"
        Send "{Esc}"
        return
    }

    ; Locate "Open Last Result: <name>" and remember its menu index.
    targetIdx := -1
    filename := ""
    for i, item in items {
        normalised := (SubStr(item, 1, 1) = "&") ? SubStr(item, 2) : item
        if (InStr(normalised, "open last result:", false) = 1) {
            targetIdx := i - 1  ; AHK array is 1-based; Win32 menu items are 0-based
            colonPos := InStr(normalised, ":")
            if (colonPos > 0)
                filename := Trim(SubStr(normalised, colonPos + 1))
            break
        }
    }

    if (targetIdx < 0) {
        ; No result waiting — benign idle state. Stay silent; the WATCHING
        ; heartbeat is the timeline anchor for "nothing to do right now".
        Send "{Esc}"
        Send "{Esc}"
        return
    }

    if (filename = LastResultSeen) {
        ; Already handled this result — benign idle state, stay silent.
        Send "{Esc}"
        Send "{Esc}"
        return
    }

    ; A genuinely new result is waiting — open a RESULT-POLL phase so the whole
    ; attempt reads as one delimited block with a time range, then handle it.
    PhaseBegin("RESULT-POLL")
    try {
        prev := (LastResultSeen = "") ? "none" : LastResultSeen
        WatchdogLog("new result: " . filename . " (previous: " . prev . ", menu idx " . targetIdx . ")")

        beforeWin := ""
        try
            beforeWin := WinGetClass("A") . " / " . WinGetTitle("A")
        WatchdogLog("active window before click: " . beforeWin)

        excelWasRunningBefore := ProcessExist("EXCEL.EXE") ? true : false

        if (!WinExist("ahk_class #32768")) {
            WatchdogLog("WARN: menu closed between read and click — aborting; will retry next tick")
            return
        }

        Sleep 200
        Loop (targetIdx + 1) {
            SendEvent "{Down}"
            Sleep 80
        }
        Sleep 200
        SendEvent "{Enter}"
        Sleep 800

        Sleep EXCEL_KILL_DELAY_MS
        excelNowRunning := ProcessExist("EXCEL.EXE") ? true : false
        clickSucceeded := excelNowRunning && !excelWasRunningBefore

        if (clickSucceeded) {
            WatchdogLog("EXPORTED (Excel launched after click; killing it so the pickup file is released)")
            KillProcess("EXCEL.EXE")
            SaveLastResult(filename)
            SetStatus("OK", "Exports recovered on " . A_ComputerName . " — " . filename . " went through")
        } else if (excelNowRunning && excelWasRunningBefore) {
            WatchdogLog("WARN: Excel already running before click — can't confirm export; will retry next tick")
            SetStatus("EXPORT_FAILING", ":warning: Exports failing on " . A_ComputerName . " — " . filename . " unconfirmed (Excel already open), retrying")
        } else {
            WatchdogLog("WARN: clicked but no Excel appeared — pickup file likely NOT written; will retry next tick")
            SetStatus("EXPORT_FAILING", ":warning: Exports failing on " . A_ComputerName . " — " . filename . " no file written, retrying")
        }
    } finally {
        PhaseEnd()
    }
}

; Returns the filename portion of an "Open Last Result: <name>" menu item,
; or "" if no such item exists in `items`. Case-insensitive match, strips
; the leading "&" accelerator if present.
ExtractLastResultFilename(items) {
    for item in items {
        normalised := (SubStr(item, 1, 1) = "&") ? SubStr(item, 2) : item
        if (InStr(normalised, "open last result:", false) = 1) {
            colonPos := InStr(normalised, ":")
            if (colonPos > 0)
                return Trim(SubStr(normalised, colonPos + 1))
        }
    }
    return ""
}

LoadLastResult() {
    global LastResultSeen, LAST_RESULT_FILE
    try {
        if (FileExist(LAST_RESULT_FILE)) {
            LastResultSeen := Trim(FileRead(LAST_RESULT_FILE), " `t`r`n")
            WatchdogLog("Loaded LastResultSeen from disk: '" . LastResultSeen . "'")
        } else {
            WatchdogLog("No last_result.txt yet — first run, LastResultSeen empty")
        }
    } catch as e {
        WatchdogLog("WARN: could not load last_result.txt: " . e.Message)
        LastResultSeen := ""
    }
}

SaveLastResult(name) {
    global LastResultSeen, LAST_RESULT_FILE
    LastResultSeen := name
    try {
        if (FileExist(LAST_RESULT_FILE))
            FileDelete LAST_RESULT_FILE
        FileAppend name, LAST_RESULT_FILE
    } catch as e {
        WatchdogLog("WARN: could not save last_result.txt: " . e.Message)
    }
}


; ==============================================================
;  Chevron flyout opener with retries (cold-boot resilient)
; ==============================================================
; Win+B is racy at cold boot: the LWin modifier sometimes leaks and Windows
; reads it as a bare Win press (opening Start) followed by 'b'. We send
; via SendInput (atomic) and verify the flyout window appeared. If it didn't,
; we Esc to dismiss whatever DID open (likely Start menu) and retry.
OpenChevronFlyoutWithRetries() {
    flyoutClass := "ahk_class TopLevelWindowForOverflowXamlIsland"
    maxAttempts := 5
    Loop maxAttempts {
        attempt := A_Index
        ; First attempt uses tight timings (mid-session); failed attempts
        ; bump up the waits to handle cold-boot / racy input states.
        escWait := attempt = 1 ? 100 : 200
        modWait := attempt = 1 ? 100 : 200
        winBWait := attempt = 1 ? 400 : 800
        enterWait := attempt = 1 ? 350 : 700
        retryWait := 1500

        Send "{Esc}"
        Sleep escWait
        Send "{LWin Up}{RWin Up}{Ctrl Up}{Alt Up}{Shift Up}"
        Sleep modWait
        SendInput "{LWin Down}b{LWin Up}"
        Sleep winBWait
        Send "{Enter}"
        Sleep enterWait
        if (WinExist(flyoutClass)) {
            if (attempt > 1)
                WatchdogLog("Chevron flyout opened on attempt " . attempt)
            return true
        }
        WatchdogLog("Flyout not detected on attempt " . attempt . " — retrying with longer waits")
        Sleep retryWait
    }
    return false
}

; ==============================================================
;  Tray menu automation (Win+B keyboard navigation)
; ==============================================================
;  Sequence:
;    Win+B           → focus the chevron in the system tray
;    {Enter}         → open the hidden-icons flyout
;    {Right} × N     → walk to QuickSync's icon (N = TRAY_RIGHT_ARROWS_IN_FLYOUT)
;    Shift+F10       → open QuickSync's context menu
;    {Down}          → highlight "Available Devices"
;    {Right}         → open the Available Devices submenu
;    {Down}          → highlight first listed device (the iD3 IP)
;    {Enter}         → connect
OpenQuickSyncTrayMenuAndConnect() {
    WatchdogLog("Driving QS tray menu for reconnect (dynamic icon lookup)")
    if (!OpenQuickSyncContextMenu()) {
        WatchdogLog("ERROR: could not locate QuickSync in tray — aborting reconnect")
        return false
    }
    ; QS context menu is now open and verified. Walk down to "Available Services".
    Loop MENU_DOWNS_TO_AVAILABLE_SERVICES {
        Send "{Down}"
        Sleep 120
    }
    ; Step 6: open the submenu
    Send "{Right}"
    Sleep 400
    ; Step 7: walk down to the iD3 in the submenu
    Loop SUBMENU_DOWNS_TO_DEVICE {
        Send "{Down}"
        Sleep 120
    }
    ; Step 8: connect
    Send "{Enter}"
    Sleep 500
    WatchdogLog("Tray menu sequence sent — connection should be re-established")
    return true
}

; ==============================================================
;  Diagnostic log
; ==============================================================
; Normal log line — timestamped and prefixed with the current phase tag, so
; every line is attributable to the cycle the watchdog was in at that moment.
WatchdogLog(msg) {
    global WATCHDOG_LOG, CurrentPhase
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    try {
        FileAppend ts . "  [" . CurrentPhase . "] " . msg . "`n", WATCHDOG_LOG
    } catch {
    }
}

; Raw log line — timestamped but NOT phase-tagged. Used for the phase BEGIN/END
; banners and for lines that carry their own explicit tag (e.g. [HEALTH]).
WatchdogRaw(line) {
    global WATCHDOG_LOG
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    try {
        FileAppend ts . "  " . line . "`n", WATCHDOG_LOG
    } catch {
    }
}

; ==============================================================
;  Slack notifications (status-change DMs via chat.postMessage)
; ==============================================================
; SetStatus DMs you ONLY when the pipeline status actually changes, so a stuck
; plate or an ongoing recovery pings once — staying in the same status is silent.
; Status values: OK / RECOVERING / RECOVERY_FAILED / iD3_DOWN / EXPORT_FAILING.
SetStatus(newStatus, slackText) {
    global CurrentStatus
    if (newStatus = CurrentStatus)
        return
    CurrentStatus := newStatus
    SlackNotify(slackText)
}

; Low-level DM — sends unconditionally (used by SetStatus and the test hotkey).
; A failed call is logged but never throws — Slack being down must not affect the
; watchdog. Short timeouts so a slow API call can't stall a recovery/poll.
SlackNotify(text) {
    global SLACK_BOT_TOKEN, SLACK_DM_USER_ID
    if (SLACK_BOT_TOKEN = "" || SLACK_DM_USER_ID = "")
        return
    try {
        body := '{"channel":"' . SLACK_DM_USER_ID . '","text":"' . SlackEscape(text) . '"}'
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(2000, 2000, 2000, 4000)  ; resolve, connect, send, receive (ms)
        req.Open("POST", "https://slack.com/api/chat.postMessage", false)
        req.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        req.SetRequestHeader("Authorization", "Bearer " . SLACK_BOT_TOKEN)
        req.Send(body)
        ; Slack answers HTTP 200 with {"ok":false,"error":"..."} on logical errors
        ; (invalid_auth, channel_not_found, missing scope, ...) — surface those so
        ; setup is debuggable instead of silently dropping pings.
        if (req.Status != 200 || InStr(req.ResponseText, '"ok":false'))
            WatchdogLog("WARN: Slack DM not delivered (HTTP " . req.Status . "): " . req.ResponseText)
    } catch as e {
        WatchdogLog("WARN: Slack notify failed: " . e.Message)
    }
}

; JSON-escapes a string for embedding in the webhook payload.
SlackEscape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", " ")
    return s
}

; ==============================================================
;  Phase tracking — delimit the script's main cycles in the log
; ==============================================================
; Each active cycle (STARTUP / RESULT-POLL / RECOVERY) is bracketed by a
; begin/end banner; PhaseEnd's banner shows the duration and the
; start->end time range so you can scan the log to a moment and see exactly
; what the watchdog was doing then. WATCHING is the idle default between them.
PhaseBegin(name) {
    global CurrentPhase, PrevPhase, PhaseStartTick, PhaseStartStamp
    PrevPhase := CurrentPhase
    CurrentPhase := name
    PhaseStartTick := A_TickCount
    PhaseStartStamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    WatchdogRaw("===== " . name . " begin =====")
}

PhaseEnd() {
    global CurrentPhase, PrevPhase, PhaseStartTick, PhaseStartStamp
    dur := FormatDuration((A_TickCount - PhaseStartTick) // 1000)
    endStamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    WatchdogRaw("===== " . CurrentPhase . " end  (" . dur . ")  " . PhaseStartStamp . " -> " . endStamp . " =====")
    CurrentPhase := PrevPhase
    return dur
}

; Idle snapshot so the timeline never has unexplained gaps. Only fires when
; genuinely idle (WATCHING) — never mid-recovery or mid-result-poll — so it
; adds at most one line per HEARTBEAT_LOG_MS and never spams.
Heartbeat() {
    global Recovering, CurrentPhase, LastReachable, LastResultSeen
    if (Recovering || CurrentPhase != "WATCHING")
        return
    qs := ProcessExist("QuickSync.exe") ? "running" : "NOT running"
    reach := LastReachable ? "reachable" : "UNREACHABLE"
    lr := (LastResultSeen = "") ? "none" : LastResultSeen
    WatchdogLog("idle - iD3 " . reach . ", QuickSync " . qs . ", last result " . lr)
}

; Rate-limited note for result-poll anomalies (menu won't open / unreadable).
; These can recur every tick, so we log at most one per HEARTBEAT_LOG_MS to
; surface a real problem without reintroducing per-tick spam.
LogPollIssue(msg) {
    global LastPollIssueTick, HEARTBEAT_LOG_MS
    if (A_TickCount - LastPollIssueTick < HEARTBEAT_LOG_MS)
        return
    LastPollIssueTick := A_TickCount
    WatchdogLog(msg)
}
