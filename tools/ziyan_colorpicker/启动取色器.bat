@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo [子砚] 取点抓色器 v1.7.4
echo 主程序: ZiYanColorPicker.py  /  抄触动：主窗MDI读图  取色面板留在抓色器内
echo.

REM 源码优先（与触动面板对齐的 v1.4）；旧 exe 仅作后备
where py >nul 2>&1
if not errorlevel 1 (
  py -3 ZiYanColorPicker.py
  if errorlevel 1 pause
  exit /b %errorlevel%
)
where python >nul 2>&1
if not errorlevel 1 (
  python ZiYanColorPicker.py
  if errorlevel 1 pause
  exit /b %errorlevel%
)
if exist "D:\Python安装包\Python文件\python.exe" (
  "D:\Python安装包\Python文件\python.exe" ZiYanColorPicker.py
  if errorlevel 1 pause
  exit /b %errorlevel%
)

if exist "ZiYanColorPicker_v134.exe" (
  start "" "ZiYanColorPicker_v134.exe"
  exit /b 0
)
if exist "ZiYanColorPicker.exe" (
  start "" "ZiYanColorPicker.exe"
  exit /b 0
)

echo 未找到 Python3，请安装并勾选 Add to PATH，或先运行 build_exe.bat 打包 exe
pause
exit /b 1
