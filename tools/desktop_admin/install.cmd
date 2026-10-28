@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo Installation did not finish. Review the error above.
  pause
  exit /b 1
)
echo Shadow Network Admin is available from the Desktop and Start menu.
pause
