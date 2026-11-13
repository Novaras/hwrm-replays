@echo off
rem hwrm-replays companion for Windows: runs replaywatch.ps1 (PowerShell, built into Windows 10 and 11; no Python needed).
rem Double-click: keeps watching for finished games while you play (close the window to stop).
rem From a command prompt: replaywatch.bat [-Profiles "<the game's Bin\Profiles folder>"] [-Watch <seconds>] [-Dry]
setlocal
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0replaywatch.ps1" -Watch 5
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0replaywatch.ps1" %*
)
if errorlevel 1 pause
