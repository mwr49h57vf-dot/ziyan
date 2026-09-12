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

REM 先把源码打成加密载荷，再打单文件 exe。发行 zip 只留 exe。
%PY% protect_build.py
if errorlevel 1 (
  echo 加密载荷失败
  pause
  exit /b 1
)

%PY% -m PyInstaller --noconfirm --clean --onefile --windowed --name ZiYan ^
  --icon ziyan.ico ^
  --add-data "ziyan.ico;." ^
  --add-data "ziyan_picker_icon.png;." ^
  --add-data "_zy_payload.bin;." ^
  --hidden-import PIL._tkinter_finder ^
  --hidden-import picker_imports ^
  --hidden-import protect_build ^
  picker_boot.py

if exist dist\ZiYan.exe (
  copy /Y dist\ZiYan.exe .\ZiYan.exe >nul
  echo.
  echo OK: %cd%\ZiYan.exe
) else (
  echo 打包失败
  pause
  exit /b 1
)
pause
