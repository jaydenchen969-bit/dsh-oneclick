@echo off
rem dsh-oneclick · Windows entry
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
)
exit /b %ERRORLEVEL%
