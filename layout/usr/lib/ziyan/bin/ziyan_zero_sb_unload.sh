#!/bin/bash
# 8-159：物理卸 ZiYanVol 注入（保留 dylib 文件便于回滚）
# 8-161-42：默认 sb_vol_thin → 保留 Filter（仅音量菜单）；
#   关 thin：touch $VAR/.ziyan_sb_vol_thin_off 后运行本脚本 --reload
# 关全零：touch $VAR/.ziyan_zero_sb_full_off 后运行本脚本 --reload
set +e
if [ -d /var/jb/usr/lib/ziyan ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  PLISTS="/var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist /var/jb/usr/lib/TweakInject/ZiYanVol.plist"
else
  VAR=/usr/lib/ziyan/var
  PLISTS="/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist"
fi
mkdir -p "$VAR"
if [ -f "$VAR/.ziyan_zero_sb_full_off" ]; then
  # 回滚全零：恢复 plist，清 full/thin
  for p in $PLISTS; do
    [ -f "${p}.ziyan_off" ] && mv -f "${p}.ziyan_off" "$p"
  done
  rm -f "$VAR/.ziyan_zero_sb_full" "$VAR/.ziyan_sb_vol_thin"
  echo "RELOADED_FILTER (full_off)"
elif [ -f "$VAR/.ziyan_sb_vol_thin_off" ]; then
  # 关 thin：卸 Filter，保留 full
  echo 1 > "$VAR/.ziyan_zero_sb_full"
  echo 1 > "$VAR/.ziyan_zero_sb_inject"
  rm -f "$VAR/.ziyan_sb_vol_thin"
  for p in $PLISTS; do
    if [ -f "$p" ]; then
      mv -f "$p" "${p}.ziyan_off"
      echo "DISABLED $p (thin_off)"
    fi
  done
else
  # 默认全零 + thin：写标志并确保 Filter 在
  echo 1 > "$VAR/.ziyan_zero_sb_full"
  echo 1 > "$VAR/.ziyan_zero_sb_inject"
  echo 1 > "$VAR/.ziyan_sb_vol_thin"
  for p in $PLISTS; do
    [ -f "${p}.ziyan_off" ] && [ ! -f "$p" ] && mv -f "${p}.ziyan_off" "$p" && echo "RESTORED_THIN $p"
  done
  echo "ZERO_FULL+THIN (keep Vol filter)"
fi
# 仅人工明确授权才允许 respring。默认与单独 --sbreload 均阻断。
allow=0
for a in "$@"; do
  [ "$a" = "--allow-manual-respring" ] && allow=1
done
if [ "$1" = "--sbreload" ] || [ "$allow" = 1 ]; then
  if [ "$allow" != 1 ]; then
    echo "BLOCKED_AUTO_SB_RESTART"
    echo "legacy --sbreload is not enough; pass --allow-manual-respring"
    exit 78
  fi
  sbreload 2>/dev/null || /var/jb/usr/bin/sbreload 2>/dev/null || killall -9 SpringBoard
fi
echo OK
