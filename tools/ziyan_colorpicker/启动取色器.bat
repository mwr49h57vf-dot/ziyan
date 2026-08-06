@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo [子砚] 取点抓色器 v1.3.4
echo 主程序: ZiYanColorPicker.py  /  协议: 手机 :50005 /status /snapshot /findtest
echo.

REM 优先已打包 exe（与 zip 同名或 build 产出）
if exist "ZiYanColorPicker_v134.exe" (
  start "" "ZiYanColorPicker_v134.exe"
  exit /b 0
)
if exist "ZiYanColorPicker.exe" (
  start "" "ZiYanColorPicker.exe"
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
where python3 >nul 2>&1
if not errorlevel 1 (
  python3 ZiYanColorPicker.py
  if errorlevel 1 pause
  exit /b %errorlevel%
)

echo 未找到 Python3，请安装并勾选 Add to PATH，或先运行 build_exe.bat 打包 exe
pause
exit /b 1
