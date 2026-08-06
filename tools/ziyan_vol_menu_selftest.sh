#!/bin/bash
# 音量−菜单自测：8-161-42 默认 sb_vol_thin → SB UIWindow；否则 App Overlay
# usage: tools/ziyan_vol_menu_selftest.sh [53|101|112|166|all]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=alpine
want="${1:-all}"

run_one() {
  local tag="$1" ip="$2"
  echo "==== selftest .$tag $ip ===="
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 "root@$ip" "bash -s" <<EOS
set +e
VAR=/usr/lib/ziyan/var
BIN=/usr/lib/ziyan/bin
DL=/Library/MobileSubstrate/DynamicLibraries
if [ -d /var/jb/usr/lib/ziyan ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
  DL=/var/jb/Library/MobileSubstrate/DynamicLibraries
fi
echo "VER=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | grep ^Version)"
# 默认 thin：全零找色外移 + SB 仅菜单
rm -f "\$VAR/.ziyan_sb_vol_thin_off" "\$VAR/.ziyan_zero_sb_full_off"
echo 1 > "\$VAR/.ziyan_zero_sb_full"
echo 1 > "\$VAR/.ziyan_sb_vol_thin"
# 确保 Vol Filter 在
for p in "\$DL/ZiYanVol.plist" /var/jb/usr/lib/TweakInject/ZiYanVol.plist; do
  [ -f "\${p}.ziyan_off" ] && [ ! -f "\$p" ] && mv -f "\${p}.ziyan_off" "\$p"
done
rm -f "\$VAR/.ziyan_vol_menu_sticky" "\$VAR/.ziyan_vol_menu_ui_meta" \
      "\$VAR/.ziyan_menu_dump" "\$VAR/.ziyan_menu_geom" "\$VAR/.ziyan_app_vol_menu_req"
rm -f "\$VAR/.ziyan_app_user_closed" "\$VAR/.ziyan_vol_disarmed"
# 武装拦截（打开过 App 或直接写 active）
echo 1 > "\$VAR/.ziyan_active"
# 触发 SB 音量菜单（等同音量−）
echo > "\$VAR/.ziyan_vol_trig"
chmod 666 "\$VAR/.ziyan_vol_trig" 2>/dev/null
# vol trig 轮询 0.5s；等 hooks 已装
sleep 2.5
STICKY=0; META=""; DUMP=0; GEOM=0; THIN=0; BTN=0
[ -f "\$VAR/.ziyan_vol_menu_sticky" ] && STICKY=1
[ -f "\$VAR/.ziyan_menu_dump" ] && DUMP=1
[ -f "\$VAR/.ziyan_menu_geom" ] && GEOM=1
[ -f "\$VAR/.ziyan_sb_vol_thin_active" ] && THIN=1
META=\$(cat "\$VAR/.ziyan_vol_menu_ui_meta" 2>/dev/null | tr -d '\r')
echo "\$META" | grep -q 'btn=custom_black55' && BTN=1
grep -q 'sb_vol_thin' "\$VAR/.ziyan_menu_geom" 2>/dev/null && BTN=1
HOOKS=\$(head -1 "\$VAR/.ziyan_hooks" 2>/dev/null | tr -d '\r')
echo "RESULT tag=$tag sticky=\$STICKY btn=\$BTN dump=\$DUMP geom=\$GEOM thin_active=\$THIN meta=\${META:-none} hooks=\${HOOKS:-none}"
# 通过：菜单 dump/geom/sticky 任一写出 + 半黑按钮样式标记
if { [ "\$STICKY" = 1 ] || [ "\$DUMP" = 1 ] || [ "\$GEOM" = 1 ]; } && [ "\$BTN" = 1 ]; then
  echo "PASS_$tag"
  exit 0
fi
# 兜底：hooks 已声明 volume_menu_only 且 geom 写出
if echo "\$HOOKS" | grep -q 'volume_menu_only' && [ "\$GEOM" = 1 ]; then
  echo "PASS_$tag"
  exit 0
fi
echo "FAIL_$tag"
exit 1
EOS
}

fail=0
while IFS='|' read -r tag ip _pass scheme _rest; do
  [[ "$tag" =~ ^# ]] && continue
  [[ -z "$tag" ]] && continue
  [[ "$scheme" == "ts" ]] && continue
  if [[ "$want" != "all" && "$want" != "$tag" ]]; then
    continue
  fi
  if ! run_one "$tag" "$ip"; then
    fail=1
  fi
done < <(grep -v '^#' "$ROOT/DEVICES.txt" | grep '|')

if [[ "$fail" == 0 ]]; then
  echo "VOL_MENU_SELFTEST_ALL_OK"
else
  echo "VOL_MENU_SELFTEST_FAIL"
  exit 1
fi
