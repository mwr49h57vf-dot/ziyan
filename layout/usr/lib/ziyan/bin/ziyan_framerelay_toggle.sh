#!/bin/bash
# 实验旗：touch $VAR/.ziyan_no_framerelay → 卸 FrameRelay Filter（默认保留）
# 回滚：rm 该旗后本脚本；生效须 --sbreload（显式一次，不循环杀 SB）
set +e
if [ -d /var/jb/usr/lib/ziyan ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  PLISTS="/var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.plist /var/jb/usr/lib/TweakInject/ZiYanFrameRelay.plist"
else
  VAR=/usr/lib/ziyan/var
  PLISTS="/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.plist"
fi
mkdir -p "$VAR"
if [ -f "$VAR/.ziyan_no_framerelay" ]; then
  for p in $PLISTS; do
    if [ -f "$p" ]; then
      mv -f "$p" "${p}.ziyan_off"
      echo "DISABLED $p"
    fi
  done
  echo "MODE=no_framerelay"
else
  for p in $PLISTS; do
    [ -f "${p}.ziyan_off" ] && mv -f "${p}.ziyan_off" "$p" && echo "RESTORED $p"
  done
  echo "MODE=framerelay_on"
fi
if [ "$1" = "--sbreload" ]; then
  sbreload 2>/dev/null || /var/jb/usr/bin/sbreload 2>/dev/null || killall -9 SpringBoard
  echo SBRELOAD=1
fi
echo OK
