#!/usr/bin/env bash
# 刀 DESK2：两段色业务门禁（强制先测 SB 桌面主色）
#   A0 fuse+scp → Home（禁先 open_app）
#   A1 embed Desktop
#   A2 ≤90s 必须「找到目标」/ Verify tap → 否则 FAIL_DESK
#   B1 点开后前台离开 SpringBoard
#   B2 「登录」→ LOGIN_PASS
# 总评：DESK_PASS && LOGIN_PASS 才 VERDICT=PASS；仅登录 = LOGIN_ONLY FAIL
# 用法: bash tools/zy_desk2_two_segment_gate.sh [53|166|all]
# 默认 53+166；禁 .171；不关 CAP53 30s 底线；不改包号
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/DESK2_GATE_${STAMP}"
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

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4" bid="$5"
  echo "[desk2] .$tag $script (no open_app before desk)"
  if [[ "$script" == "ios8p.lua" ]]; then
    scp_r "$DESKTOP_IOS8P" "$ip" /private/var/mobile/Media/ZiYan/ios8p.lua
  else
    scp_r "$DESKTOP_IOS7" "$ip" /private/var/mobile/Media/ZiYan/ios7.lua
  fi
  bash "$ROOT/tools/zy_miss_fuse_emergency.sh" "$tag" 2>&1 | tee -a "$OUT/fuse_${tag}.txt" | tail -2

  ssh_r "$ip" "TAG=$tag SCHEME=$scheme SCRIPT=$script BID=$bid bash -s" <<'EOS' | tee "$OUT/gate_${tag}.txt"
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
DESK_PASS=0
LOGIN_PASS=0
LOGIN_ONLY=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

sb_pid() {
  ps -axo pid,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1
}
toast_hist() {
  if [ -s "$VAR/.ziyan_toast_hist" ]; then
    tr '\n' '|' <"$VAR/.ziyan_toast_hist" 2>/dev/null
  else
    tr '\n' '|' <"$VAR/.ziyan_toast_dump" 2>/dev/null
  fi
}
go_home() {
  local n="${1:-8}"
  local i F
  for i in $(seq 1 "$n"); do
    echo 1 >"$VAR/.ziyan_go_home"; chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
    sleep 0.9; rm -f "$VAR/.ziyan_go_home"
    F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
    echo "HOME try$i FRONT=$F"
    echo "$F" | grep -qi springboard && return 0
  done
  return 1
}

SB0=$(sb_pid)
echo "META VER=$VER SB0=$SB0 SCRIPT=$SCRIPT BID=$BID DESK2=1"
mkdir -p "$VAR" "$MEDIA"
echo 1 >"$VAR/.ziyan_no_auto_keep"; chmod 666 "$VAR/.ziyan_no_auto_keep" 2>/dev/null || true
rm -f "$VAR/.ziyan_open_app" "$VAR/.ziyan_allow_sb_find" "$VAR/.ziyan_embed_off" \
  "$VAR/.ziyan_light" "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_keep_daemon" \
  "$VAR/.ziyan_session_keep" "$VAR/.ziyan_active"
# 清旧 toast，防残留「登录」假绿
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

# —— A0 Home（禁止先 open_app）——
go_home 10
FRONT0=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "A0 FRONT=$FRONT0"
echo "$FRONT0" | grep -qi springboard && pass A0_home || fail A0_not_home_$FRONT0

# 等一帧（.53 CAP53 可能最多 ~30s）
for t in $(seq 1 35); do
  echo 1 >"$VAR/.ziyan_force_recap"; chmod 666 "$VAR/.ziyan_force_recap" 2>/dev/null
  echo "nonce=desk2_a0_$t" >"$VAR/.ziyan_frame_req"; chmod 666 "$VAR/.ziyan_frame_req"
  sleep 1
  L=$(tail -1 "$VAR/.ziyan_framecap_log" 2>/dev/null)
  echo "$L" | grep -qE 'ok=1 via=' && { echo "A0_FRAME t=$t $L"; break; }
done

# —— A1 embed（仍不 open_app）——
rm -f "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded" "$VAR/.ziyan_embed_alive"
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
printf '1\n' >"$VAR/.ziyan_embed_on"
date +%s >"$VAR/.ziyan_project_active"
echo "nonce=desk2_${TAG}_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_on" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_project_active" 2>/dev/null
sleep 3
EMB=0
[ -f "$VAR/.ziyan_lua_embedded" ] && EMB=1
[ -f "$VAR/.ziyan_embed_alive" ] && EMB=1
grep -q 'ok=1' "$VAR/.ziyan_embed_ack" 2>/dev/null && EMB=1
[ "$EMB" = 1 ] && pass A1_embed || fail A1_embed

# —— A2 桌面主色：必须「找到目标」；出现登录但无找到目标 → LOGIN_ONLY ——
TAP_OK=0
LOGIN_SEEN=0
DESK_MISS=0
deadline=$(( $(date +%s) + 90 ))
LAST=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  # 若中途被拉进游戏且还没桌面 tap，仍等「找到目标」；不提前 PASS
  T=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -1 | sed 's/^text=//')
  [ -n "$T" ] && [ "$T" != "$LAST" ] && echo "TOAST=$T" && LAST=$T
  H=$(toast_hist)
  echo "$H" | grep -qE '找到目标|tap success|Verify' && TAP_OK=1
  echo "$H" | grep -q '登录' && LOGIN_SEEN=1
  echo "$H" | grep -q '桌面未找到' && DESK_MISS=1
  grep -qE 'tap success|iOS7 tap|iPhone8Plus tap' "$VAR/.ziyan_verify_log" 2>/dev/null && TAP_OK=1
  [ -f "$VAR/.ziyan_biz_tapped" ] && TAP_OK=1
  if [ "$TAP_OK" = 1 ]; then
    break
  fi
  # 保持尽量在 Home：若无 tap 却已进游戏，记警告但仍等找到目标
  F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  if ! echo "$F" | grep -qi springboard; then
    echo "WARN left_home_before_desk_tap FRONT=$F"
  fi
  sleep 1
done

echo "TOAST_HIST=$(toast_hist | tail -c 500)"
echo "TAP_OK=$TAP_OK LOGIN_SEEN=$LOGIN_SEEN DESK_MISS=$DESK_MISS"
FRONT_A2=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "FRONT_A2=$FRONT_A2"

if [ "$TAP_OK" = 1 ]; then
  DESK_PASS=1
  pass A2_desk_find_tap
else
  fail A2_FAIL_DESK
  if [ "$LOGIN_SEEN" = 1 ]; then
    LOGIN_ONLY=1
    echo "LOGIN_ONLY=1 (desk skipped / primary miss)"
    fail A2_LOGIN_ONLY_not_desk_pass
  fi
fi

# —— B1 点开后应离开 SpringBoard（由脚本 tap；禁门禁代 open_app）——
if [ "$DESK_PASS" = 1 ]; then
  d1=$(( $(date +%s) + 45 ))
  APP_OK=0
  while [ "$(date +%s)" -lt "$d1" ]; do
    F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
    echo "B1 FRONT=$F"
    if ! echo "$F" | grep -qi springboard; then
      APP_OK=1
      break
    fi
    sleep 1
  done
  [ "$APP_OK" = 1 ] && pass B1_left_home || fail B1_still_home
else
  echo "SKIP B1 (no desk tap)"
fi

# —— B2 登录 toast ——
if [ "$DESK_PASS" = 1 ]; then
  d2=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$d2" ]; do
    H=$(toast_hist)
    echo "$H" | grep -q '登录' && { LOGIN_PASS=1; echo "TOAST_HIST_HIT=登录"; break; }
    sleep 1
  done
  [ "$LOGIN_PASS" = 1 ] && pass B2_login || fail B2_login_timeout
else
  # 无桌面 PASS 时，即使看见登录也不给 LOGIN_PASS 总评
  echo "SKIP B2_login_credit (desk failed); LOGIN_SEEN=$LOGIN_SEEN"
fi

printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"; chmod 666 "$VAR/.ziyan_kill_scripts" 2>/dev/null || true
sleep 2
rm -f "$VAR/.ziyan_active" "$VAR/.ziyan_keep_daemon" "$VAR/.ziyan_session_keep" 2>/dev/null

SB1=$(sb_pid)
echo "SB1=$SB1 SB0=$SB0"
echo "DESK_PASS=$DESK_PASS LOGIN_PASS=$LOGIN_PASS LOGIN_ONLY=$LOGIN_ONLY FAIL=$FAIL"

if [ "$DESK_PASS" = 1 ] && [ "$LOGIN_PASS" = 1 ] && [ "$FAIL" = 0 ]; then
  echo "VERDICT=PASS"
elif [ "$LOGIN_ONLY" = 1 ]; then
  echo "VERDICT=FAIL_LOGIN_ONLY"
else
  echo "VERDICT=FAIL"
fi
echo "META end=$(date +%s)"
EOS
}

case "$WANT" in
  all)
    run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game
    run_one 166 192.168.31.166 rootful ios7.lua com.ljzbbadao.game
    ;;
  53) run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game ;;
  166) run_one 166 192.168.31.166 rootful ios7.lua com.ljzbbadao.game ;;
  *) echo "usage: $0 [53|166|all]"; exit 2 ;;
esac

PASS_N=0
FAIL_N=0
for f in "$OUT"/gate_*.txt; do
  [ -f "$f" ] || continue
  echo "---- $(basename "$f") ----"
  tail -25 "$f"
  if grep -q 'VERDICT=PASS' "$f"; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done

{
  echo "# DESK2 two-segment gate"
  echo "stamp=$STAMP want=$WANT"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  if [ "$FAIL_N" = 0 ] && [ "$PASS_N" -gt 0 ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
  echo "NOTE=login-only is FAIL; desk primary must toast 找到目标 on Home"
} | tee "$OUT/VERDICT.md"

echo "OUT=$OUT"
