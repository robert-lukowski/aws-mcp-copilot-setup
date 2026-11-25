@echo off
setlocal
cd /d "%~dp0"
set "MCP_SETUP_PWSH="
where pwsh.exe >nul 2>&1
if not errorlevel 1 set "MCP_SETUP_PWSH=pwsh.exe"
if not defined MCP_SETUP_PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "MCP_SETUP_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined MCP_SETUP_PWSH (
  echo PowerShell 7 was not found. Starting the prerequisite installer.
  powershell.exe -NoLogo -NoProfile -File "%~dp0bootstrap.ps1"
  goto finished
)
"%MCP_SETUP_PWSH%" -NoLogo -NoProfile -File "%~dp0setup.ps1"
:finished
set "MCP_SETUP_EXIT=%ERRORLEVEL%"
if not "%MCP_SETUP_EXIT%"=="0" echo Setup did not finish. Review the message above and README.md. No execution policy was changed.
pause
exit /b %MCP_SETUP_EXIT%
