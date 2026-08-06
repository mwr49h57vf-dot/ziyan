@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo [子砚] 打包 ZiYanColorPicker.exe ...
where python >nul 2>&1
if errorlevel 1 (
  where py >nul 2>&1
  if errorlevel 1 (
    echo 未找到 Python，请先安装 Python3 并勾选 Add to PATH
    pause
    exit /b 1
  )
  set PY=py -3
) else (
  set PY=python
)

%PY% -m pip install -U pip pillow pyinstaller -q
if errorlevel 1 (
  echo pip 失败
  pause
  exit /b 1
)

%PY% -m PyInstaller --noconfirm --clean --onefile --windowed --name ZiYanColorPicker_v134 ^
  --hidden-import PIL._tkinter_finder ^
  --hidden-import formats ^
  ZiYanColorPicker.py

if exist dist\ZiYanColorPicker_v134.exe (
  copy /Y dist\ZiYanColorPicker_v134.exe .\ZiYanColorPicker_v134.exe >nul
  copy /Y dist\ZiYanColorPicker_v134.exe .\ZiYanColorPicker.exe >nul
  echo.
  echo OK: %cd%\ZiYanColorPicker_v134.exe
  echo OK: %cd%\ZiYanColorPicker.exe
) else (
  echo 打包失败
  pause
  exit /b 1
)
pause
