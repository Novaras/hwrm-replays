@echo off
rem hwrm-replays companion for Windows: runs replaywatch.ps1 (PowerShell, built into Windows 10 and 11; no Python needed).
rem Double-click: keeps watching for finished games while you play (close the window to stop).
rem From a command prompt: replaywatch.bat [-Profiles "<the game's Bin\Profiles folder>"] [-Watch <seconds>] [-Dry]
rem From Steam's launch options: "<path>\replaywatch.bat" --run %command% -enablerecord
rem   starts the game, with the tool in a minimised window that converts replays while the game runs and closes after it.
setlocal
if /i "%~1"=="--run" goto run
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0replaywatch.ps1" -Watch 5
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0replaywatch.ps1" %*
)
if errorlevel 1 pause
exit /b

:run
rem The game's command line is everything after --run, exactly as Steam passed it. The game starts even if the tool fails.
set "GAME=%*"
call set "GAME=%%GAME:*--run =%%"
start "hwrm-replays" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0replaywatch.ps1" -WhileGameRuns
%GAME%
