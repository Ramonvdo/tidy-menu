@echo off
rem Double-click to install. Runs install.ps1 with the execution policy bypassed
rem for this one run only, then keeps the window open so the summary stays readable.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
