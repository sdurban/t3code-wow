@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0windows\launcher.ps1" %*
set "T3WOW_EXIT=%ERRORLEVEL%"
if "%~1"=="" if not "%T3WOW_EXIT%"=="0" pause
exit /b %T3WOW_EXIT%
