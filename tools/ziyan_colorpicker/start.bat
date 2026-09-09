@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "ZiYan.exe" (
  start "" "ZiYan.exe"
  exit /b 0
)
echo missing ZiYan.exe
pause
exit /b 1
