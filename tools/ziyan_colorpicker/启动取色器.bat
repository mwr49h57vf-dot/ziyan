@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo [子砚] 取点抓色器 v1.7.5
echo.

if exist "ZiYan.exe" (
  start "" "ZiYan.exe"
  exit /b 0
)

where python >nul 2>&1
if not errorlevel 1 (
  python ZiYanColorPicker.py
  if errorlevel 1 pause
  exit /b %errorlevel%
)
where py >nul 2>&1
if not errorlevel 1 (
  py -3 ZiYanColorPicker.py
  if errorlevel 1 pause
  exit /b %errorlevel%
)

echo 未找到 ZiYan.exe 或 Python3
pause
exit /b 1
