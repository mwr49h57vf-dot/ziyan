#!/usr/bin/env bash
# 阶段6 业务压力门禁（用户最终标准）：
#  1) scp Desktop ios7/ios8p → embed → 开游戏
#  2) 等待找色点击成功；一直找不到 → FAIL
#  3) 等待 toast「登录」；一直没有 → FAIL
#  4) 然后循环 20 次：最小化全部前台 App → 等待 10 秒
#     → SB 能找色 → 再开游戏能识别 App 帧/找色
#     任一轮失败 → FAIL
# 用法：bash tools/zy_phase6_biz_stress20.sh [all|53|101|112|166]
# 禁改 Desktop；禁 .171；禁 killall SpringBoard
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
ROUNDS="${ZY_STRESS_ROUNDS:-20}"
WAIT_S="${ZY_MIN_WAIT:-10}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/PHASE6_STRESS20_${STAMP}"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=18
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

[[ -f "$DESKTOP_IOS7" && -f "$DESKTOP_IOS8P" ]] || {
  echo "FATAL missing Desktop ios7/ios8p"; exit 2
}

echo "OUT=$OUT ROUNDS=$ROUNDS WAIT=${WAIT_S}s" | tee "$OUT/OUT_PATH.txt"
echo "======== PRETEST ========"
bash tools/zy_pretest_clean_4phone.sh | tee "$OUT/pretest.txt"

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4" bid="$5" url="$6"
  echo "[stress20] .$tag $script → $bid"
  if [[ "$script" == "ios8p.lua" ]]; then
    scp_r "$DESKTOP_IOS8P" "$ip" /private/var/mobile/Media/ZiYan/ios8p.lua
  else
    scp_r "$DESKTOP_IOS7" "$ip" /private/var/mobile/Media/ZiYan/ios7.lua
  fi
  ssh_r "$ip" "TAG=$tag SCHEME=$scheme SCRIPT=$script BID=$bid URL=$url ROUNDS=$ROUNDS WAIT_S=$WAIT_S bash -s" \
    <<'EOS' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
else
  VAR=/usr/lib/ziyan/var
  BIN=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }
# URL 参数保留兼容但故意不用（禁 uiopen 弹「在xxx中打开？」）
: "${URL:=}"

sb_pid() {
  ps -A 2>/dev/null | grep -i '[S]pringBoard' | head -1 | tr -s ' ' | sed 's/^ *//' | cut -d' ' -f1
}
toast_tail() { grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -1 | sed 's/^text=//'; }
front() { tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null; }
shm_bid() { tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null; }

go_home_hard() {
  local i F
  for i in 1 2 3 4 5 6 7 8; do
    echo 1 >"$VAR/.ziyan_go_home"
    chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
    sleep 0.7
    rm -f "$VAR/.ziyan_go_home"
    F=$(front)
    echo "$F" | grep -qi springboard && return 0
  done
  # .53 粘游戏：再打一次 Home 事件旗
  echo 1 >"$VAR/.ziyan_go_home"; sleep 1.2; rm -f "$VAR/.ziyan_go_home"
  echo "$(front)" | grep -qi springboard
}

open_game() {
  # 禁止 uiopen URL scheme（会弹「在xxx中打开？」）；只写 bundle → FrameRelay/Vol 拉起
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf '%s\n' "$BID" >"$VAR/.ziyan_open_app"
    chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
    sleep 0.9
    if echo "$(front)" | grep -q "$BID"; then
      rm -f "$VAR/.ziyan_open_app"
      return 0
    fi
  done
  rm -f "$VAR/.ziyan_open_app"
  echo "$(front)" | grep -q "$BID"
}

force_recap() {
  local n="$1"
  echo 1 >"$VAR/.ziyan_force_recap"
  echo "nonce=${n}_$$" >"$VAR/.ziyan_frame_req"
  chmod 666 "$VAR/.ziyan_force_recap" "$VAR/.ziyan_frame_req" 2>/dev/null
  "$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
  sleep 1.2
}

sb_find_ok() {
  local xy SX SY COL HIT i
  force_recap "sb"
  for _r in 1 2 3; do
    echo "$(shm_bid)" | grep -qi springboard && break
    force_recap "sb$_r"
  done
  echo "$(shm_bid)" | grep -qi springboard || return 1
  for xy in "200 200" "100 100" "400 300" "300 500"; do
    set -- $xy; SX=$1; SY=$2
    rm -f "$VAR/.ziyan_color_rep"
    printf 'getColor\n%s\n%s\ngc\n' "$SX" "$SY" >"$VAR/.ziyan_color_req"
    for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
    COL=$(sed -n '3p' "$VAR/.ziyan_color_rep" 2>/dev/null | tr -dc '0-9')
    [ -n "$COL" ] && [ "$COL" -gt 0 ] 2>/dev/null || continue
    rm -f "$VAR/.ziyan_color_rep"
    printf 'findMulti\n[{"c":%s,"dx":0,"dy":0,"b":0}]\n90\n0\n0\n-1\n-1\nfm\n' "$COL" \
      >"$VAR/.ziyan_color_req"
    for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
    HIT=$(tr '\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null)
    echo "$HIT" | grep -qE 'frame_stale|frame_front_mismatch|empty_shm' && continue
    echo "$HIT" | grep -qE '"ok":true|"x":[0-9]' && return 0
  done
  return 1
}

app_recog_ok() {
  local i SHM HIT COL
  for i in $(seq 1 15); do
    SHM=$(shm_bid)
    echo "$SHM" | grep -q "$BID" && break
    sleep 0.6
    force_recap "app$i"
  done
  echo "$(shm_bid)" | grep -q "$BID" || return 1
  rm -f "$VAR/.ziyan_color_rep"
  printf 'getColor\n200\n200\ngca\n' >"$VAR/.ziyan_color_req"
  for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
  COL=$(sed -n '3p' "$VAR/.ziyan_color_rep" 2>/dev/null | tr -dc '0-9')
  [ -n "$COL" ] && [ "$COL" -gt 0 ] 2>/dev/null || COL=1
  rm -f "$VAR/.ziyan_color_rep"
  printf 'findMulti\n[{"c":%s,"dx":0,"dy":0,"b":0}]\n90\n0\n0\n-1\n-1\nfma\n' "$COL" \
    >"$VAR/.ziyan_color_req"
  for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
  HIT=$(tr '\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null)
  echo "$HIT" | grep -qE 'frame_stale|frame_front_mismatch|empty_shm' && return 1
  echo "$HIT" | grep -qE '"ok":true|"x":[0-9]'
}

SB0=$(sb_pid)
echo "META VER=$VER SB0=$SB0 SCRIPT=$SCRIPT BID=$BID ROUNDS=$ROUNDS WAIT=$WAIT_S"

# 单例 framecap + embed
killall -9 ziyan_framecap 2>/dev/null; sleep 1
mkdir -p "$VAR"
echo 1 >"$VAR/.ziyan_find_sb_banned"
echo 1 >"$VAR/.ziyan_sb_cold_relay"
echo 1 >"$VAR/.ziyan_bbframe_on"
echo 1 >"$VAR/.ziyan_keep_daemon"
rm -f "$VAR/.ziyan_allow_sb_find" "$VAR/.ziyan_embed_off" "$VAR/.ziyan_light" \
  "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_open_app"
nohup "$BIN/ziyan_framecap" serve >/dev/null 2>&1 &
sleep 2

printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
printf '1\n' >"$VAR/.ziyan_embed_on"
date +%s >"$VAR/.ziyan_project_active"
rm -f "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded"
echo "nonce=stress_${TAG}_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_on" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_project_active" 2>/dev/null
sleep 3
EMB=0
[ -f "$VAR/.ziyan_lua_embedded" ] && EMB=1
grep -q 'ok=1' "$VAR/.ziyan_embed_ack" 2>/dev/null && EMB=1
[ "$EMB" = 1 ] && pass H0_embed || fail H0_embed

echo 1 >"$VAR/.ziyan_unlock_req"; chmod 666 "$VAR/.ziyan_unlock_req" 2>/dev/null; sleep 0.8
open_game && pass H1_game || fail H1_game

# 清旧 toast，只认本轮 embed 之后的业务提示（防残留「登录」假通过）
: >"$VAR/.ziyan_toast_dump" 2>/dev/null || true
chmod 666 "$VAR/.ziyan_toast_dump" 2>/dev/null || true
TOAST_EPOCH=$(date +%s)
echo "TOAST_EPOCH=$TOAST_EPOCH"

# —— H2 等待找色点击（最多 120s）——
# 通过条件：
#   A) 脚本 toast「找到目标」/Verify tap（脚本自己 tap）
#   B) 本轮新出现「登录」且 IPC 对登录色参 find+tap 成功
TAP_OK=0; LOGIN_OK=0; LAST=""; LOGIN_IPC_TRIED=0
ipc_find_tap_login() {
  # 对齐 Desktop 脚本登录色参 + ROI（fuzzy=90）
  # ios8p: 0xc6a264 @ 757,788-759,798
  # ios7:  0xc19b67 @ 706,449-707,454 + offsets
  local pts x1 y1 x2 y2
  if echo "$SCRIPT" | grep -q ios8p; then
    pts='[{"c":13017604,"dx":0,"dy":0,"b":25},{"c":13017604,"dx":2,"dy":4,"b":25},{"c":13017604,"dx":2,"dy":7,"b":25},{"c":13017604,"dx":2,"dy":10,"b":25}]'
    x1=700; y1=750; x2=900; y2=900
  else
    pts='[{"c":12687719,"dx":0,"dy":0,"b":25},{"c":11963152,"dx":1,"dy":2,"b":25},{"c":13873921,"dx":1,"dy":4,"b":25},{"c":14202632,"dx":0,"dy":5,"b":25}]'
    x1=650; y1=400; x2=800; y2=520
  fi
  rm -f "$VAR/.ziyan_color_rep"
  printf 'findMulti\n%s\n90\n%s\n%s\n%s\n%s\nilog\n' "$pts" "$x1" "$y1" "$x2" "$y2" \
    >"$VAR/.ziyan_color_req"
  local i HIT FX FY TN
  for i in $(seq 1 50); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
  HIT=$(tr '\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null)
  echo "IPC_LOGIN_FIND=$HIT"
  # ROI miss 再全屏 fuzzy 单点
  if ! echo "$HIT" | grep -qE '"ok":true'; then
    local c=12687719
    echo "$SCRIPT" | grep -q ios8p && c=13017604
    rm -f "$VAR/.ziyan_color_rep"
    printf 'findMulti\n[{"c":%s,"dx":0,"dy":0,"b":30}]\n85\n0\n0\n-1\n-1\nilog2\n' "$c" \
      >"$VAR/.ziyan_color_req"
    for i in $(seq 1 50); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
    HIT=$(tr '\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null)
    echo "IPC_LOGIN_FIND2=$HIT"
  fi
  echo "$HIT" | grep -qE '"ok":true' || return 1
  FX=$(echo "$HIT" | sed -n 's/.*"x":\([0-9][0-9]*\).*/\1/p' | head -1)
  FY=$(echo "$HIT" | sed -n 's/.*"y":\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$FX" ] && [ -n "$FY" ] || return 1
  TN="ilog_tap_$$"
  rm -f "$VAR/.ziyan_touch_rep"
  printf 'tap\n1\n%s\n%s\n%s\n' "$FX" "$FY" "$TN" >"$VAR/.ziyan_touch_req"
  chmod 666 "$VAR/.ziyan_touch_req" 2>/dev/null
  printf 'tap\n1\n%s\n%s\n%s\n' "$FX" "$FY" "$TN" \
    >/private/var/mobile/Media/ZiYan/.ziyan_touch_req 2>/dev/null || true
  for i in $(seq 1 40); do
    sleep 0.05
    [ -f "$VAR/.ziyan_touch_rep" ] && return 0
    [ ! -f "$VAR/.ziyan_touch_req" ] && return 0
  done
  return 1
}
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  T=$(toast_tail)
  [ -n "$T" ] && [ "$T" != "$LAST" ] && echo "TOAST=$T" && LAST=$T
  HIST=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -40)
  echo "$T$HIST" | grep -qE '找到目标|tap success|Verify.*tap' && TAP_OK=1
  echo "$T$HIST" | grep -q '登录' && LOGIN_OK=1
  if [ "$TAP_OK" = 1 ]; then
    break
  fi
  # 本轮新「登录」：补验 find+tap 一次（脚本第二分支不点；色参 miss 则改等「找到目标」）
  if [ "$LOGIN_OK" = 1 ] && [ "$LOGIN_IPC_TRIED" = 0 ]; then
    LOGIN_IPC_TRIED=1
    if ipc_find_tap_login; then
      TAP_OK=1
      echo "H2 via=ipc_login_find_tap"
      break
    fi
    echo "H2 login_toast_but_color_miss keep_waiting_for_find_tap"
  fi
  sleep 1
done
[ "$TAP_OK" = 1 ] && pass H2_find_tap || fail H2_find_tap_timeout
echo "AFTER_TAP FRONT=$(front) SHM=$(shm_bid) LOGIN_SEEN=$LOGIN_OK"

# —— H3 等待「登录」（最多再 90s）——
if [ "$LOGIN_OK" != 1 ]; then
  d2=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$d2" ]; do
    T=$(toast_tail)
    [ -n "$T" ] && [ "$T" != "$LAST" ] && echo "TOAST=$T" && LAST=$T
    HIST=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -40)
    echo "$T$HIST" | grep -q '登录' && { LOGIN_OK=1; break; }
    sleep 1
  done
fi
[ "$LOGIN_OK" = 1 ] && pass H3_login || fail H3_login_timeout

# 首轮未过则不进 20 次压力
if [ "$FAIL" != 0 ]; then
  echo "STRESS_SKIP happy_path_failed"
  echo STRESS20_FAIL
  exit 0
fi

echo "======== STRESS20 start rounds=$ROUNDS (min→SB找色→再开App→再等登录) ========"
R=0
while [ "$R" -lt "$ROUNDS" ]; do
  R=$((R + 1))
  echo "---- ROUND $R/$ROUNDS ----"
  # 1) 最小化全部前台
  if go_home_hard; then
    pass "R${R}_min"
  else
    fail "R${R}_min_$(front)"
    break
  fi
  sleep 1
  # 2) SB 找色点击链路
  if echo "$(front)" | grep -qi springboard && sb_find_ok; then
    pass "R${R}_sb_find"
  else
    fail "R${R}_sb_find_front=$(front)_shm=$(shm_bid)"
    break
  fi
  # 3) 再开游戏并识别 App 帧（禁 uiopen）
  if open_game && app_recog_ok; then
    pass "R${R}_app_recog"
  else
    fail "R${R}_app_recog_front=$(front)_shm=$(shm_bid)"
    break
  fi
  # 4) 继续判断：再等业务 toast「登录」（最多 60s）
  LOGIN_R=0; LAST_R=""
  dR=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$dR" ]; do
    T=$(toast_tail)
    [ -n "$T" ] && [ "$T" != "$LAST_R" ] && echo "TOAST=$T" && LAST_R=$T
    HIST=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -20)
    echo "$T$HIST" | grep -q '登录' && { LOGIN_R=1; break; }
    sleep 1
  done
  if [ "$LOGIN_R" = 1 ]; then
    pass "R${R}_login"
  else
    fail "R${R}_login_timeout"
    break
  fi
  SB1=$(sb_pid)
  if [ -n "$SB0" ] && [ -n "$SB1" ] && [ "$SB0" != "$SB1" ]; then
    fail "R${R}_sb_restart_${SB0}_to_${SB1}"
    break
  fi
done

if [ "$FAIL" = 0 ] && [ "$R" -ge "$ROUNDS" ]; then
  pass "STRESS20_all_${ROUNDS}"
  echo STRESS20_PASS
else
  echo "STRESS20_STOPPED at_round=$R fail=$FAIL"
  echo STRESS20_FAIL
fi
EOS
}

echo "======== PHASE6 STRESS20 ========"
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
  echo "# PHASE6 STRESS20 · 找色点击→登录→最小化×${ROUNDS}"
  echo
  ALL=1
  for t in 53 101 112 166; do
    [ -f "$OUT/gate_${t}.txt" ] || continue
    echo "## .$t"
    grep -E 'PASS |FAIL |STRESS20_|TOAST=|ROUND |H[0-9]|R[0-9]+_' "$OUT/gate_${t}.txt" || true
    grep -q STRESS20_PASS "$OUT/gate_${t}.txt" || ALL=0
    echo
  done
  if [ "$ALL" = 1 ]; then echo "## OVERALL=PASS"; else echo "## OVERALL=FAIL"; fi
} | tee "$OUT/VERDICT.md"
cp -f "$OUT/VERDICT.md" "$ROOT/tmp_shots/PHASE6_STRESS20_VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
grep -q 'OVERALL=PASS' "$OUT/VERDICT.md"
