@echo off
rem Start the Gen1Online+ server (Windows).  Double-click this file, or run it
rem from a terminal with options, e.g.  server\start.bat --port 8000
rem When Windows Firewall asks about Python, allow it on PRIVATE networks so
rem friends on your Wi-Fi can join.
setlocal
set "SCRIPT=%~dp0gts_server.py"
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 "%SCRIPT%" %*
  goto done
)
where python >nul 2>nul
if %errorlevel%==0 (
  python "%SCRIPT%" %*
  goto done
)
echo Python 3 is not installed. Get it from https://www.python.org/downloads/
echo and tick "Add python.exe to PATH" in the installer, then run this again.
:done
pause
