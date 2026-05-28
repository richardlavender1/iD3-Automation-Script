@echo off
setlocal EnableExtensions

REM ============================================================
REM  QuickSync pickup  ->  Google Drive copier (with transfer log)
REM ------------------------------------------------------------
REM  Run on a schedule (e.g. every 2 min) by Task Scheduler.
REM  Logs ONLY the files it actually transferred (and any errors),
REM  into the SAME folder as the watchdog log, so the two logs
REM  corroborate each other:
REM     watchdog.log          -> "EXPORTED PlateX 11:15"
REM     robocopy-transfers.log-> "transferred PlateX 11:17"
REM  Join them by filename to trace a plate end-to-end, or see
REM  exactly which hop dropped it.
REM ============================================================

REM ===== FILL IN PER MACHINE =====
set "SRC=C:\PATH\TO\QuickSync\pickup\folder"
set "DST=C:\PATH\TO\GoogleDrive\synced\folder"
REM ===============================

REM Logs live next to THIS .bat. Deploy it in the watchdog folder
REM (alongside quicksync-watchdog.ahk) so all logs share one location.
set "TLOG=%~dp0robocopy-transfers.log"
set "LASTRUN=%~dp0robocopy-last.tmp"

REM /R:2 /W:5  -> at most 2 retries, 5s apart. A file still being written gets
REM              retried, but we never hang on robocopy's default 1,000,000 retries.
REM /NP /NDL /NJH /NJS /NC /NS -> log just the copied file names, no header/summary noise.
REM Identical files (same name/size/time) are skipped automatically, so an idle
REM run copies nothing and the run log comes back empty.
robocopy "%SRC%" "%DST%" *.xlsx /R:2 /W:5 /NP /NDL /NJH /NJS /NC /NS /LOG:"%LASTRUN%"
set RC=%ERRORLEVEL%

REM robocopy exit codes: 0 = nothing copied, 1-7 = files copied / minor, >=8 = error.
if %RC% GEQ 8 goto :error
goto :ok

:error
>>"%TLOG%" echo [%DATE% %TIME%] ROBOCOPY ERROR rc=%RC% - source/dest unreachable or copy failed
if exist "%LASTRUN%" type "%LASTRUN%" >>"%TLOG%"
goto :done

:ok
REM Only write a block when something was actually transferred (non-empty run log),
REM so 720 idle runs/day don't bloat the handshake log.
if not exist "%LASTRUN%" goto :done
set "SIZE="
for %%A in ("%LASTRUN%") do set "SIZE=%%~zA"
if "%SIZE%"=="" goto :done
if "%SIZE%"=="0" goto :done
>>"%TLOG%" echo [%DATE% %TIME%] transferred:
type "%LASTRUN%" >>"%TLOG%"
goto :done

:done
del "%LASTRUN%" 2>nul
endlocal
