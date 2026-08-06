#!/usr/bin/env bash
# 阶段6 真实业务门禁（用户指定）：
#   scp Desktop ios7.lua / ios8p.lua → 开游戏 → 等找色点击
#   → 等 toast「登录」→ 最小化 → SB 找色 → 再开游戏识别
# 失败判据：一直找不到色 / 一直无「登录」/ 中间任一步无法识别
# 用法：bash tools/zy_phase6_biz_script_gate.sh [all|53|101|112|166]
# 禁改 Desktop 脚本内容；禁 .171
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/PHASE6_BIZ_${STAMP}"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

[[ -f "$DESKTOP_IOS7" && -f "$DESKTOP_IOS8P" ]] || {
  echo "FATAL missing Desktop ios7/ios8p"; exit 2
}

echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "======== PRETEST ========"
bash tools/zy_pretest_clean_4phone.sh | tee "$OUT/pretest.txt"

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4" bid="$5" url="$6"
  echo "[biz] .$tag $script → $bid"
  if [[ "$script" == "ios8p.lua" ]]; then
    scp_r "$DESKTOP_IOS8P" "$ip" /private/var/mobile/Media/ZiYan/ios8p.lua
  else
    scp_r "$DESKTOP_IOS7" "$ip" /private/var/mobile/Media/ZiYan/ios7.lua
  fi
  ssh_r "$ip" "TAG=$tag SCHEME=$scheme SCRIPT=$script BID=$bid URL=$url bash -s" <<'EOS' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
else
  VAR=/usr/lib/ziyan/var
  BIN=/usr/lib/ziyan/bin
fi
# 禁 uiopen URL（会弹「在xxx中打开？」）；开 App 只用 .ziyan_open_app + bundle
MEDIA=/private/var/mobile/Media/ZiYan
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

sb_pid() {
  ps -A 2>/dev/null | grep -i '[S]pringBoard' | head -1 | tr -s ' ' | sed 's/^ *//' | cut -d' ' -f1
}
SB0=$(sb_pid)
echo "META VER=$VER SB0=$SB0 SCRIPT=$SCRIPT BID=$BID"

# 单例 framecap
killall -9 ziyan_framecap 2>/dev/null; sleep 1
mkdir -p "$VAR"
echo 1 >"$VAR/.ziyan_find_sb_banned"
echo 1 >"$VAR/.ziyan_sb_cold_relay"
echo 1 >"$VAR/.ziyan_bbframe_on"
echo 1 >"$VAR/.ziyan_keep_daemon"
rm -f "$VAR/.ziyan_allow_sb_find" "$VAR/.ziyan_embed_off" "$VAR/.ziyan_light" "$VAR/.ziyan_user_stopped"
# 186：清陈旧 toast/verify，避免上一轮「登录」污染 B2/B3
rm -f "$VAR/.ziyan_toast_dump" "$VAR/.ziyan_toast_hist" \
  "$VAR/.ziyan_verify_log" "$VAR/.ziyan_biz_tapped"
: >"$VAR/.ziyan_toast_dump"
: >"$VAR/.ziyan_toast_hist"
: >"$VAR/.ziyan_verify_log"
chmod 666 "$VAR/.ziyan_toast_dump" "$VAR/.ziyan_toast_hist" \
  "$VAR/.ziyan_verify_log" 2>/dev/null
nohup "$BIN/ziyan_framecap" serve >/dev/null 2>&1 &
sleep 2

# embed Desktop 脚本
rm -f "$VAR/.ziyan_open_app"
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
printf '1\n' >"$VAR/.ziyan_embed_on"
date +%s >"$VAR/.ziyan_project_active"
rm -f "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded"
echo "nonce=biz_$TAG_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_on" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_project_active" 2>/dev/null
sleep 3
EMB=0
[ -f "$VAR/.ziyan_lua_embedded" ] && EMB=1
grep -q 'ok=1' "$VAR/.ziyan_embed_ack" 2>/dev/null && EMB=1
[ "$EMB" = 1 ] && pass B0_embed || fail B0_embed
echo "ACK=$(tr '\n' ' ' <"$VAR/.ziyan_embed_ack" 2>/dev/null)"

# —— B1 开游戏（仅 bundle open_app；禁 uiopen URL →「在xxx中打开？」）——
echo 1 >"$VAR/.ziyan_unlock_req"; chmod 666 "$VAR/.ziyan_unlock_req" 2>/dev/null; sleep 0.8
APP_OK=0
for i in $(seq 1 12); do
  printf '%s\n' "$BID" >"$VAR/.ziyan_open_app"
  chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
  sleep 0.9
  F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "B1 try$i FRONT=$F"
  echo "$F" | grep -q "$BID" && { APP_OK=1; break; }
done
rm -f "$VAR/.ziyan_open_app"
[ "$APP_OK" = 1 ] && pass B1_game || fail B1_game_front

# —— B2 等待找色点击成功（toast 含「找到目标」或 Verify tap success；最多 90s）——
# 同时监视「登录」
TAP_OK=0; LOGIN_OK=0
deadline=$(( $(date +%s) + 90 ))
LAST_TOAST=""
# 186/187：优先 .ziyan_toast_hist（环形 text=）；dump 仅最新布局快照
toast_hist() {
  if [ -s "$VAR/.ziyan_toast_hist" ]; then
    tr '\n' '|' <"$VAR/.ziyan_toast_hist" 2>/dev/null
  else
    tr '\n' '|' <"$VAR/.ziyan_toast_dump" 2>/dev/null
  fi
}
while [ "$(date +%s)" -lt "$deadline" ]; do
  T=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -1 | sed 's/^text=//')
  [ -n "$T" ] && [ "$T" != "$LAST_TOAST" ] && echo "TOAST=$T" && LAST_TOAST=$T
  H=$(toast_hist)
  echo "$H" | grep -qE '找到目标|tap success|Verify' && TAP_OK=1
  echo "$H" | grep -q '登录' && LOGIN_OK=1
  grep -qE 'tap success|iOS7 tap|iPhone8Plus tap' "$VAR/.ziyan_verify_log" 2>/dev/null && TAP_OK=1
  [ -f "$VAR/.ziyan_biz_tapped" ] && TAP_OK=1
  if [ "$TAP_OK" = 1 ]; then
    pass B2_find_tap
    break
  fi
  sleep 1
done
[ "$TAP_OK" = 1 ] && pass B2_find_tap || fail B2_find_tap_timeout
echo "FRONT_AFTER_TAP=$(tr -d '\n' <"$VAR/.ziyan_front_bid") SHM=$(tr -d '\n' <"$VAR/.ziyan_shm_front_bid")"
echo "CAP=$(tail -6 "$VAR/.ziyan_framecap_log" 2>/dev/null | tr '\n' '|')"
echo "TOAST_HIST=$(toast_hist | tail -c 400)"

# —— B3 等待「登录」toast（点击后业务态；最多再等 60s）——
if [ "$LOGIN_OK" != 1 ]; then
  d2=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$d2" ]; do
    H=$(toast_hist)
    echo "$H" | grep -q '登录' && { LOGIN_OK=1; echo "TOAST_HIST_HIT=登录"; break; }
    sleep 1
  done
fi
[ "$LOGIN_OK" = 1 ] && pass B3_login_toast || fail B3_login_toast_timeout

# —— B4 最小化全部 App → SB ——
for _h in 1 2 3 4 5 6; do
  echo 1 >"$VAR/.ziyan_go_home"; chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
  sleep 0.8; rm -f "$VAR/.ziyan_go_home"
  F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "B4 try$_h FRONT=$F"
  echo "$F" | grep -qi springboard && break
done
if ! echo "$(tr -d '\r\n' <"$VAR/.ziyan_front_bid")" | grep -qi springboard; then
  killall -9 Preferences 2>/dev/null || true
  # 不杀游戏进程名乱杀；再 go_home
  echo 1 >"$VAR/.ziyan_go_home"; sleep 1; rm -f "$VAR/.ziyan_go_home"
fi
FRONT4=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "$FRONT4" | grep -qi springboard && pass B4_min_home || fail B4_min_$FRONT4

# —— B5 SB 找色（任意点 getColor→find）——
sleep 1
echo 1 >"$VAR/.ziyan_force_recap"
echo "nonce=biz_sb_$$" >"$VAR/.ziyan_frame_req"
"$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
sleep 1.5
SHM5=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
echo "B5 SHM_BID=$SHM5"
echo "$SHM5" | grep -qi springboard && pass B5_shm_bid || {
  # 再试两次
  for _r in 1 2; do
    echo 1 >"$VAR/.ziyan_force_recap"; echo "nonce=biz_sb2_$$" >"$VAR/.ziyan_frame_req"
    "$BIN/ziyan_framecap" once >/dev/null 2>&1 || true; sleep 1.5
    SHM5=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
    echo "$SHM5" | grep -qi springboard && break
  done
  echo "$SHM5" | grep -qi springboard && pass B5_shm_bid || fail B5_shm_bid_$SHM5
}
SB_FIND=0
for xy in "200 200" "100 100" "400 300"; do
  set -- $xy; SX=$1; SY=$2
  rm -f "$VAR/.ziyan_color_rep"
  printf 'getColor\n%s\n%s\ngc\n' "$SX" "$SY" >"$VAR/.ziyan_color_req"
  for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
  COL=$(sed -n '3p' "$VAR/.ziyan_color_rep" | tr -dc '0-9')
  [ -n "$COL" ] && [ "$COL" -gt 0 ] 2>/dev/null || continue
  rm -f "$VAR/.ziyan_color_rep"
  printf 'findMulti\n[{"c":%s,"dx":0,"dy":0,"b":0}]\n90\n0\n0\n-1\n-1\nfm\n' "$COL" >"$VAR/.ziyan_color_req"
  for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
  HIT=$(tr '\n' ' ' <"$VAR/.ziyan_color_rep")
  echo "B5 FIND@$SX,$SY col=$COL $HIT"
  echo "$HIT" | grep -qE '"ok":true|"x":[0-9]' && { SB_FIND=1; break; }
done
[ "$SB_FIND" = 1 ] && pass B5_sb_find || fail B5_sb_find

# —— B6 再开游戏（仅 open_app bundle；禁 uiopen URL）——
APP2=0
for i in 1 2 3 4 5 6 7 8; do
  printf '%s\n' "$BID" >"$VAR/.ziyan_open_app"
  chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
  sleep 0.9
  F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "$F" | grep -q "$BID" && { APP2=1; break; }
done
rm -f "$VAR/.ziyan_open_app"
[ "$APP2" = 1 ] && pass B6_reopen || fail B6_reopen
# 等盖戳（预算刷新后应不再卡死）
RECOG=0
for i in $(seq 1 20); do
  sleep 0.8
  SHM6=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
  echo "B6 try$i SHM=$SHM6"
  echo "$SHM6" | grep -q "$BID" && { RECOG=1; break; }
done
[ "$RECOG" = 1 ] && pass B6_app_frame || fail B6_app_frame_stale
# 再找一枪（全屏任意色）证明可识别
rm -f "$VAR/.ziyan_color_rep"
printf 'getColor\n200\n200\ngc2\n' >"$VAR/.ziyan_color_req"
for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
COL2=$(sed -n '3p' "$VAR/.ziyan_color_rep" | tr -dc '0-9')
rm -f "$VAR/.ziyan_color_rep"
printf 'findMulti\n[{"c":%s,"dx":0,"dy":0,"b":0}]\n90\n0\n0\n-1\n-1\nfm2\n' "${COL2:-1}" >"$VAR/.ziyan_color_req"
for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
HIT2=$(tr '\n' ' ' <"$VAR/.ziyan_color_rep")
echo "B6 FIND $HIT2"
echo "$HIT2" | grep -qE '"ok":true|"x":[0-9]' && pass B6_app_find || fail B6_app_find
echo "$HIT2" | grep -qE 'frame_stale|frame_front_mismatch|empty_shm' && fail B6_still_stale || pass B6_no_stale_err

SB1=$(sb_pid)
echo "SB1=$SB1 SB0=$SB0"
if [ -n "$SB0" ] && [ -n "$SB1" ] && [ "$SB0" = "$SB1" ]; then
  pass B7_sb_stable
else
  [ -n "$SB1" ] && pass B7_sb_alive || fail B7_sb
fi

if [ "$FAIL" = 0 ]; then echo BIZ_PASS; else echo BIZ_FAIL; fi
EOS
}

echo "======== PHASE6 BIZ ios7/ios8p ========"
case "$WANT" in
  all)
    run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game 'xqhyios://'
    run_one 101 192.168.31.101 rootful ios7.lua com.xztl.ios 'xztl://'
    run_one 112 192.168.31.112 rootful ios7.lua com.xztl.ios 'xztl://'
    run_one 166 192.168.31.166 rootful ios7.lua com.xztl.ios 'xztl://'
    ;;
  53) run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game 'xqhyios://' ;;
  101) run_one 101 192.168.31.101 rootful ios7.lua com.xztl.ios 'xztl://' ;;
  112) run_one 112 192.168.31.112 rootful ios7.lua com.xztl.ios 'xztl://' ;;
  166) run_one 166 192.168.31.166 rootful ios7.lua com.xztl.ios 'xztl://' ;;
  *) echo "bad $WANT"; exit 2 ;;
esac

{
  echo "# PHASE6 BIZ SCRIPT GATE"
  echo
  ALL=1
  for t in 53 101 112 166; do
    [ -f "$OUT/gate_${t}.txt" ] || continue
    echo "## .$t"
    grep -E 'PASS |FAIL |BIZ_|TOAST=|B[0-9] ' "$OUT/gate_${t}.txt" || true
    grep -q BIZ_PASS "$OUT/gate_${t}.txt" || ALL=0
    echo
  done
  if [ "$ALL" = 1 ]; then echo "## OVERALL=PASS"; else echo "## OVERALL=FAIL"; fi
} | tee "$OUT/VERDICT.md"
cp -f "$OUT/VERDICT.md" "$ROOT/tmp_shots/PHASE6_BIZ_VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
grep -q 'OVERALL=PASS' "$OUT/VERDICT.md"
