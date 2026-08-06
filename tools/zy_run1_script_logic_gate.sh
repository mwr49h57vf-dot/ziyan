#!/usr/bin/env bash
# 刀 RUN1：按 Desktop 脚本逻辑验收（认「找到目标」+tap，不拆链等登录）
#   Home → embed ios7/ios8p → ≤90s 「找到目标」/Verify → 离开 SB
#   「登录」仅附加观察，不挡 PASS；一直「色点A未找到」= FAIL_NO_FIND
#   FAIL 机落盘：Home GC/FIND 色点A + toast_hist（不擅自改色）
# 用法: bash tools/zy_run1_script_logic_gate.sh [all|53|101|112|166]
# 默认四机；禁 .171；不关 CAP53；保持 199
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/RUN1_GATE_${STAMP}"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

[[ -f "$DESKTOP_IOS7" && -f "$DESKTOP_IOS8P" ]] || {
  echo "FATAL missing Desktop ios7/ios8p"; exit 2
}
echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "WANT=$WANT" | tee -a "$OUT/OUT_PATH.txt"

# ios7 色点A（与 Desktop 同步，仅用于 FAIL 取证）
IOS7_A_PTS='[{"c":9250329,"dx":0,"dy":0,"b":0},{"c":9121568,"dx":0,"dy":2,"b":0},{"c":8070423,"dx":0,"dy":4,"b":0},{"c":8070938,"dx":0,"dy":6,"b":0}]'
IOS7_A_ROI="1010 294 1010 300 90"
# ios8p 色点A
IOS8_A_PTS='[{"c":16645615,"dx":0,"dy":0,"b":0},{"c":16711423,"dx":1,"dy":2,"b":0},{"c":16777200,"dx":2,"dy":3,"b":0},{"c":16645601,"dx":2,"dy":7,"b":0}]'
IOS8_A_ROI="2011 283 2013 290 90"

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4"
  echo "[run1] .$tag $script (script logic: 找到目标+tap)"
  if [[ "$script" == "ios8p.lua" ]]; then
    scp_r "$DESKTOP_IOS8P" "$ip" /private/var/mobile/Media/ZiYan/ios8p.lua
  else
    scp_r "$DESKTOP_IOS7" "$ip" /private/var/mobile/Media/ZiYan/ios7.lua
  fi
  bash "$ROOT/tools/zy_miss_fuse_emergency.sh" "$tag" 2>&1 | tee -a "$OUT/fuse_${tag}.txt" | tail -2

  ssh_r "$ip" "TAG=$tag SCHEME=$scheme SCRIPT=$script bash -s" <<'EOS' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
else
  VAR=/usr/lib/ziyan/var
  BIN=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
VER=$(dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\([^ ]*\).*/\1/p')
FAIL=0
FIND_TAP=0
CLICK=0
NO_FIND=0
LOGIN_SEEN=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

toast_hist() {
  if [ -s "$VAR/.ziyan_toast_hist" ]; then
    tr '\n' '|' <"$VAR/.ziyan_toast_hist" 2>/dev/null
  else
    tr '\n' '|' <"$VAR/.ziyan_toast_dump" 2>/dev/null
  fi
}
go_home() {
  local i F
  for i in $(seq 1 10); do
    echo 1 >"$VAR/.ziyan_go_home"; chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
    sleep 0.9; rm -f "$VAR/.ziyan_go_home"
    F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
    echo "HOME try$i FRONT=$F"
    echo "$F" | grep -qi springboard && return 0
  done
  return 1
}

echo "META VER=$VER SCRIPT=$SCRIPT RUN1=1 RULE=find_tap_not_login_toast"
mkdir -p "$VAR" "$MEDIA"
echo 1 >"$VAR/.ziyan_no_auto_keep"; chmod 666 "$VAR/.ziyan_no_auto_keep" 2>/dev/null || true
rm -f "$VAR/.ziyan_open_app" "$VAR/.ziyan_embed_off" "$VAR/.ziyan_user_stopped" \
  "$VAR/.ziyan_keep_daemon" "$VAR/.ziyan_session_keep" "$VAR/.ziyan_active"
rm -f "$VAR/.ziyan_toast_dump" "$VAR/.ziyan_toast_hist" \
  "$VAR/.ziyan_verify_log" "$VAR/.ziyan_biz_tapped"
: >"$VAR/.ziyan_toast_dump"
: >"$VAR/.ziyan_toast_hist"
: >"$VAR/.ziyan_verify_log"
chmod 666 "$VAR/.ziyan_toast_dump" "$VAR/.ziyan_toast_hist" \
  "$VAR/.ziyan_verify_log" 2>/dev/null

launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || \
  launchctl kickstart -k com.ziyan.framecap 2>/dev/null || true
sleep 1.2

# A0 Home — 禁止 open_app
go_home 10
FRONT0=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "A0 FRONT=$FRONT0"
echo "$FRONT0" | grep -qi springboard && pass A0_home || fail A0_not_home

for t in $(seq 1 20); do
  echo 1 >"$VAR/.ziyan_force_recap"; chmod 666 "$VAR/.ziyan_force_recap" 2>/dev/null
  echo "nonce=run1_a0_$t" >"$VAR/.ziyan_frame_req"; chmod 666 "$VAR/.ziyan_frame_req"
  sleep 1
  L=$(tail -1 "$VAR/.ziyan_framecap_log" 2>/dev/null)
  echo "$L" | grep -qE 'ok=1 via=' && { echo "A0_FRAME t=$t"; break; }
done

# A1 embed Desktop（脚本自己找色+tap）
rm -f "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded" "$VAR/.ziyan_embed_alive"
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
printf '1\n' >"$VAR/.ziyan_embed_on"
date +%s >"$VAR/.ziyan_project_active"
echo "nonce=run1_${TAG}_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_on" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_project_active" 2>/dev/null
sleep 3
EMB=0
[ -f "$VAR/.ziyan_lua_embedded" ] && EMB=1
[ -f "$VAR/.ziyan_embed_alive" ] && EMB=1
[ "$EMB" = 1 ] && pass A1_embed || fail A1_embed

# A2 等「找到目标」/Verify — 不以「登录」为成功
deadline=$(( $(date +%s) + 90 ))
LAST=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  T=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -1 | sed 's/^text=//')
  [ -n "$T" ] && [ "$T" != "$LAST" ] && echo "TOAST=$T" && LAST=$T
  H=$(toast_hist)
  echo "$H" | grep -qE '找到目标' && FIND_TAP=1
  echo "$H" | grep -q '登录' && LOGIN_SEEN=1
  echo "$H" | grep -q '色点A未找到' && NO_FIND=1
  grep -qE 'tap success|iOS7 tap|iPhone8Plus tap' "$VAR/.ziyan_verify_log" 2>/dev/null && FIND_TAP=1
  [ -f "$VAR/.ziyan_biz_tapped" ] && FIND_TAP=1
  [ "$FIND_TAP" = 1 ] && break
  sleep 1
done

echo "TOAST_HIST=$(toast_hist | tail -c 600)"
echo "FIND_TAP=$FIND_TAP LOGIN_SEEN=$LOGIN_SEEN NO_FIND=$NO_FIND"
FRONT_A2=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "FRONT_A2=$FRONT_A2"

if [ "$FIND_TAP" = 1 ]; then
  pass A2_FIND_TAP
else
  fail A2_FAIL_NO_FIND
  echo "NOTE=script_ran_but_colorA_miss_on_home (not waiting_login)"
fi

# A3 点击后应离开 SpringBoard（脚本 tap，门禁不代 open_app）
if [ "$FIND_TAP" = 1 ]; then
  d1=$(( $(date +%s) + 45 ))
  while [ "$(date +%s)" -lt "$d1" ]; do
    F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
    echo "A3 FRONT=$F"
    if ! echo "$F" | grep -qi springboard; then
      CLICK=1
      break
    fi
    # Verify 已写也算点击意图达成
    grep -qE 'tap success' "$VAR/.ziyan_verify_log" 2>/dev/null && CLICK=1 && break
    sleep 1
  done
  [ "$CLICK" = 1 ] && pass A3_CLICK || fail A3_still_home
else
  echo "SKIP A3 (no find/tap)"
fi

# 登录仅观察
[ "$LOGIN_SEEN" = 1 ] && echo "OBS_LOGIN=1" || echo "OBS_LOGIN=0"

printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"; chmod 666 "$VAR/.ziyan_kill_scripts" 2>/dev/null || true
sleep 2
rm -f "$VAR/.ziyan_active" "$VAR/.ziyan_keep_daemon" 2>/dev/null

echo "FIND_TAP=$FIND_TAP CLICK=$CLICK FAIL=$FAIL"
if [ "$FIND_TAP" = 1 ] && [ "$CLICK" = 1 ] && [ "$FAIL" = 0 ]; then
  echo "VERDICT=PASS"
elif [ "$FIND_TAP" = 0 ]; then
  echo "VERDICT=FAIL_NO_FIND"
else
  echo "VERDICT=FAIL"
fi
echo "META end=$(date +%s)"
EOS

  # FAIL 取证：Home 上色点A GC/FIND
  if ! grep -q 'VERDICT=PASS' "$OUT/gate_${tag}.txt" 2>/dev/null; then
    local pts roi x1 y1 x2 y2 deg
    if [[ "$script" == "ios8p.lua" ]]; then
      pts="$IOS8_A_PTS"
      read -r x1 y1 x2 y2 deg <<<"$IOS8_A_ROI"
    else
      pts="$IOS7_A_PTS"
      read -r x1 y1 x2 y2 deg <<<"$IOS7_A_ROI"
    fi
    echo "[run1] dig colorA on Home .$tag" | tee -a "$OUT/dig_${tag}.txt"
    ssh_r "$ip" "SCHEME=$scheme X1=$x1 Y1=$y1 X2=$x2 Y2=$y2 DEG=$deg bash -s" <<R | tee -a "$OUT/dig_${tag}.txt"
set +e
if [ "\$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
for i in 1 2 3 4 5 6; do
  echo 1 >"\$V/.ziyan_go_home"; sleep 0.8; rm -f "\$V/.ziyan_go_home"
  echo "\$(tr -d '\\r\\n' <\$V/.ziyan_front_bid)" | grep -qi springboard && break
done
echo 1 >"\$V/.ziyan_force_recap"
echo "nonce=run1_dig" >"\$V/.ziyan_frame_req"
sleep 2
echo FRONT=\$(tr -d '\\r\\n' <\$V/.ziyan_front_bid)
echo SHM=\$(tr -d '\\r\\n' <\$V/.ziyan_shm_front_bid)
echo ORIENT=\$(tr '\\n' ' ' <\$V/.ziyan_orient 2>/dev/null)
echo TOAST_HIST=\$(tr '\\n' '|' <\$V/.ziyan_toast_hist 2>/dev/null | tail -c 400)
rm -f "\$V/.ziyan_color_rep"
printf 'getColor\\n%s\\n%s\\ngc\\n' "\$X1" "\$Y1" >"\$V/.ziyan_color_req"
for i in \$(seq 1 60); do [ -f "\$V/.ziyan_color_rep" ] && break; sleep 0.05; done
echo GC=\$(tr '\\n' '|' <\$V/.ziyan_color_rep)
rm -f "\$V/.ziyan_color_rep"
printf '%s\\n' findMulti '$pts' "\$DEG" "\$X1" "\$Y1" "\$X2" "\$Y2" digA >"\$V/.ziyan_color_req"
for i in \$(seq 1 80); do [ -f "\$V/.ziyan_color_rep" ] && break; sleep 0.05; done
echo FIND=\$(tr '\\n' '|' <\$V/.ziyan_color_rep)
R
  fi
}

case "$WANT" in
  all)
    run_one 53 192.168.31.53 rootless ios8p.lua
    run_one 101 192.168.31.101 rootful ios7.lua
    run_one 112 192.168.31.112 rootful ios7.lua
    run_one 166 192.168.31.166 rootful ios7.lua
    ;;
  53) run_one 53 192.168.31.53 rootless ios8p.lua ;;
  101) run_one 101 192.168.31.101 rootful ios7.lua ;;
  112) run_one 112 192.168.31.112 rootful ios7.lua ;;
  166) run_one 166 192.168.31.166 rootful ios7.lua ;;
  *) echo "usage: $0 [all|53|101|112|166]"; exit 2 ;;
esac

PASS_H=0; FAIL_H=0
for f in "$OUT"/gate_*.txt; do
  [ -f "$f" ] || continue
  echo "---- $(basename "$f") ----"
  tail -25 "$f"
  if grep -q 'VERDICT=PASS' "$f"; then PASS_H=$((PASS_H+1)); else FAIL_H=$((FAIL_H+1)); fi
done
{
  echo "# RUN1 script-logic gate"
  echo "stamp=$STAMP want=$WANT"
  echo "PASS_HOSTS=$PASS_H FAIL_HOSTS=$FAIL_H"
  echo "RULE=embed Desktop; PASS=找到目标+tap; login toast not required"
  if [ "$FAIL_H" = 0 ] && [ "$PASS_H" -gt 0 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
