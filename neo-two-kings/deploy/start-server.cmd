@echo off
REM ============================================================
REM  NeoTwoKings dedicated server launcher
REM
REM  Usage: put this file next to NeoTwoKings.exe and run it.
REM
REM  Why this file exists:
REM  NeoTwoKings.exe is a Windows GUI-subsystem program, and server
REM  mode requires --server to be placed AFTER the `--` separator.
REM  If you forget the `--`, the program runs as a HEADLESS CLIENT
REM  instead: the process stays alive, prints almost nothing, and
REM  never listens on the port -- looking exactly like "the server
REM  did not start". This script removes that possibility.
REM
REM  This file is intentionally ASCII-only: cmd.exe reads .cmd files
REM  using the console code page, so non-ASCII text would be garbled.
REM ============================================================

setlocal
cd /d "%~dp0"

if not exist "%~dp0logs" mkdir "%~dp0logs"

echo. >> "%~dp0logs\server.log"
echo ============================================================ >> "%~dp0logs\server.log"
echo [start] %date% %time% >> "%~dp0logs\server.log"

echo Starting NeoTwoKings server...
echo Log file: %~dp0logs\server.log
echo Press Ctrl+C to stop.
echo.

"%~dp0NeoTwoKings.exe" --headless -- --server >> "%~dp0logs\server.log" 2>&1

echo.
echo Server process exited with code %ERRORLEVEL%
echo Check the log: %~dp0logs\server.log
pause
