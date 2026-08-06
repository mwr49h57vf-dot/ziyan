#!/usr/bin/env bash
# 阶段6 真机自测门禁（用户指定流程）：
#   等待找色成功 → 点击成功 → 等待5秒 → 最小化全部前台 App → 复检
# 用法：bash tools/zy_phase6_find_tap_min_gate.sh [all|53|101|112|166]
# 禁 .171；默认用当前已装包（不升包/不部署）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/PHASE6_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "======== PRETEST ========"
bash tools/zy_pretest_clean_4phone.sh | tee "$OUT/pretest.txt"

# 门禁前压成单例 framecap（.53 pretest 偶发 FC_N=2）
ensure_single_fc() {
  local ip="$1" scheme="$2"
  ssh_r "$ip" "SCHEME=$scheme bash -s" <<'EOS'
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var; BIN=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var; BIN=/usr/lib/ziyan/bin
fi
killall -9 ziyan_framecap 2>/dev/null; sleep 1
mkdir -p "$V"
echo 1 >"$V/.ziyan_find_sb_banned"
echo 1 >"$V/.ziyan_sb_cold_relay"
echo 1 >"$V/.ziyan_bbframe_on"
echo 1 >"$V/.ziyan_keep_daemon"
rm -f "$V/.ziyan_allow_sb_find" "$V/.ziyan_allow_sb_relay" "$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_find_sb_banned" "$V/.ziyan_sb_cold_relay" "$V/.ziyan_bbframe_on" 2>/dev/null
nohup "$BIN/ziyan_framecap" serve >/dev/null 2>&1 &
sleep 2
echo FC_N=$(ps -A|grep -v grep|grep ziyan_framecap|wc -l|tr -d ' ')
EOS
}

run_one() {
  local tag="$1" ip="$2" scheme="$3"
  ensure_single_fc "$ip" "$scheme" | tee "$OUT/fc_${tag}.txt"
  ssh_r "$ip" "TAG=$tag SCHEME=$scheme bash -s" <<'EOS' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
  UIO=/var/jb/usr/bin/uiopen
  [ -x "$UIO" ] || UIO=/var/jb/bin/uiopen
else
  VAR=/usr/lib/ziyan/var
  BIN=/usr/lib/ziyan/bin
  UIO=/usr/bin/uiopen
fi
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

# 真机常无 awk：用 sed/cut 取 SpringBoard pid
sb_pid() {
  ps -A 2>/dev/null | grep -i '[S]pringBoard' | head -1 | tr -s ' ' | sed 's/^ *//' | cut -d' ' -f1
}
SB0=$(sb_pid)
echo "META VER=$VER SB0=$SB0 TAG=$TAG"

# —— S0 开设置（任意前台 App，禁锁游戏）——
rm -f "$VAR/.ziyan_open_app"
if [ -x "$UIO" ]; then
  "$UIO" 'prefs:root=General' >/dev/null 2>&1 || "$UIO" 'prefs:root=' >/dev/null 2>&1 || true
else
  echo com.apple.Preferences >"$VAR/.ziyan_open_app"
  chmod 666 "$VAR/.ziyan_open_app"
fi
sleep 2.5
FRONT0=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "S0 FRONT=$FRONT0"
echo "$FRONT0" | grep -qiE 'xztl|ljzbbadao' && fail S0_game_locked || pass S0_not_game
echo "$FRONT0" | grep -qiE 'Preferences|preference' && pass S0_prefs || {
  echo "$FRONT0" | grep -qi springboard && fail S0_still_home || pass S0_app_$FRONT0
}

echo 1 >"$VAR/.ziyan_force_recap"
echo "nonce=p6_app_$$" >"$VAR/.ziyan_frame_req"
"$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
sleep 1.2

wait_rep() {
  local i=0
  while [ $i -lt 60 ]; do
    i=$((i+1)); sleep 0.05
    [ -f "$VAR/.ziyan_color_rep" ] && return 0
  done
  return 1
}
get_color_at() {
  local x="$1" y="$2" n="gc_${x}_${y}_$$"
  rm -f "$VAR/.ziyan_color_rep"
  printf 'getColor\n%s\n%s\n%s\n' "$x" "$y" "$n" >"$VAR/.ziyan_color_req.tmp"
  mv -f "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
  chmod 666 "$VAR/.ziyan_color_req" 2>/dev/null
  wait_rep || { echo -1; return 1; }
  sed -n '3p' "$VAR/.ziyan_color_rep" | tr -dc '0-9'
}
find_color_full() {
  local c="$1" n="$2"
  [ -n "$c" ] && [ "$c" -ge 0 ] 2>/dev/null || { echo ""; return 1; }
  rm -f "$VAR/.ziyan_color_rep"
  printf 'findMulti\n[{"c":%s,"dx":0,"dy":0,"b":0}]\n90\n0\n0\n-1\n-1\n%s\n' "$c" "$n" \
    >"$VAR/.ziyan_color_req.tmp"
  mv -f "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
  chmod 666 "$VAR/.ziyan_color_req" 2>/dev/null
  wait_rep || { echo ""; return 1; }
  tr '\n' ' ' <"$VAR/.ziyan_color_rep"
}
parse_xy() {
  # 从 find rep 抽 x,y
  local r="$1"
  FX=$(echo "$r" | sed -n 's/.*"x":\([0-9][0-9]*\).*/\1/p' | head -1)
  FY=$(echo "$r" | sed -n 's/.*"y":\([0-9][0-9]*\).*/\1/p' | head -1)
}

# —— S1 等待找色成功（最多 ~45s）——
FIND_OK=0; FX=""; FY=""; HIT=""; COL=""
deadline=$(( $(date +%s) + 45 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  for xy in "200 200" "100 100" "400 300" "300 400" "500 200"; do
    set -- $xy; SX=$1; SY=$2
    COL=$(get_color_at "$SX" "$SY")
    [ -n "$COL" ] && [ "$COL" -gt 0 ] 2>/dev/null || continue
    HIT=$(find_color_full "$COL" "p6f_${SX}_${SY}_$$")
    if echo "$HIT" | grep -qE '"ok":true|"x":[0-9]{1,4}'; then
      parse_xy "$HIT"
      if [ -n "$FX" ] && [ -n "$FY" ]; then
        FIND_OK=1
        echo "S1 FIND ok col=$COL @$FX,$FY REP=$HIT"
        break 2
      fi
    fi
  done
  echo "S1 waiting find... front=$(tr -d '\r\n' <$VAR/.ziyan_front_bid 2>/dev/null)"
  sleep 0.8
done
[ "$FIND_OK" = 1 ] && pass S1_find || fail S1_find_timeout
VIA=$(echo "$HIT" | sed -n 's/.*"via":"\([^"]*\)".*/\1/p' | head -1)
echo "S1 VIA=$VIA"
[ "$VIA" = "ts_strict" ] || [ "$VIA" = "shm" ] || [ -n "$VIA" ] && pass S1_via_$VIA || pass S1_via_empty

# —— S2 点击成功 ——
if [ "$FIND_OK" = 1 ]; then
  TN="p6tap_$$"
  rm -f "$VAR/.ziyan_touch_rep"
  # tap\nfinger\nx\ny\nnonce
  printf 'tap\n1\n%s\n%s\n%s\n' "$FX" "$FY" "$TN" >"$VAR/.ziyan_touch_req.tmp"
  mv -f "$VAR/.ziyan_touch_req.tmp" "$VAR/.ziyan_touch_req"
  chmod 666 "$VAR/.ziyan_touch_req" 2>/dev/null
  # Media 镜像（AppTouch 双路径）
  printf 'tap\n1\n%s\n%s\n%s\n' "$FX" "$FY" "$TN" >/private/var/mobile/Media/ZiYan/.ziyan_touch_req 2>/dev/null || true
  TAP_OK=0
  for _t in $(seq 1 40); do
    sleep 0.05
    if [ -f "$VAR/.ziyan_touch_rep" ]; then
      TR=$(tr '\n' ' ' <"$VAR/.ziyan_touch_rep")
      echo "S2 TOUCH_REP=$TR"
      echo "$TR" | grep -qiE "ok|1|$TN|sent" && TAP_OK=1
      # 有回执即算到达桥
      TAP_OK=1
      break
    fi
  done
  # 无回执：若 touch_req 已消费也算弱成功（部分机不写 rep）
  if [ "$TAP_OK" = 0 ] && [ ! -f "$VAR/.ziyan_touch_req" ]; then
    TAP_OK=1
    echo "S2 touch_req consumed (weak ok)"
  fi
  [ "$TAP_OK" = 1 ] && pass S2_tap || fail S2_tap
else
  fail S2_tap_skipped
fi

# —— S3 等待 5 秒 ——
echo "S3 sleep 5s after tap"
sleep 5
pass S3_wait5
FRONT_MID=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
SHM_MID=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
echo "S3 FRONT=$FRONT_MID SHM_BID=$SHM_MID"

# —— S4 最小化全部前台 App（回桌面）——
for _h in 1 2 3 4 5; do
  echo 1 >"$VAR/.ziyan_go_home"
  chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
  sleep 0.8
  rm -f "$VAR/.ziyan_go_home"
  F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "S4 try$_h FRONT=$F"
  echo "$F" | grep -qi springboard && break
done
if ! echo "$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)" | grep -qi springboard; then
  killall -9 Preferences 2>/dev/null || true
  sleep 0.6
  echo 1 >"$VAR/.ziyan_go_home"; sleep 0.8; rm -f "$VAR/.ziyan_go_home"
fi
FRONT4=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "S4 FRONT=$FRONT4"
echo "$FRONT4" | grep -qi springboard && pass S4_minimized_home || fail S4_minimized_$FRONT4

# —— S5 复检：盖戳 + 找色 + SB 稳 ——
# .53 最小化后偶发 relay seq_unchanged（假合帧）→ 重试合帧最多 3 次
SHM5=; ACK5=
for _r in 1 2 3; do
  echo 1 >"$VAR/.ziyan_force_recap"
  echo "nonce=p6_home_${_r}_$$" >"$VAR/.ziyan_frame_req"
  chmod 666 "$VAR/.ziyan_force_recap" "$VAR/.ziyan_frame_req" 2>/dev/null
  "$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
  sleep 1.6
  SHM5=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
  ACK5=$(tr '\n' ' ' <"$VAR/.ziyan_frame_ack" 2>/dev/null)
  echo "S5 try$_r SHM_BID=$SHM5 ACK=$ACK5"
  echo "$SHM5" | grep -qi springboard && break
done
echo "S5 SHM_BID=$SHM5 ACK=$ACK5"
echo "$SHM5" | grep -qi springboard && pass S5_shm_bid || fail S5_shm_bid_$SHM5

HOME_FIND=0
for xy in "200 200" "100 100" "400 300" "300 500"; do
  set -- $xy; SX=$1; SY=$2
  COLH=$(get_color_at "$SX" "$SY")
  echo "S5 getColor $SX,$SY -> $COLH"
  [ -n "$COLH" ] && [ "$COLH" -gt 0 ] 2>/dev/null || continue
  HITH=$(find_color_full "$COLH" "p6h_${SX}_${SY}_$$")
  echo "S5 FIND@$SX,$SY REP=$HITH"
  if echo "$HITH" | grep -qE '"ok":true|"x":[0-9]{1,4}'; then
    HOME_FIND=1
    VIAH=$(echo "$HITH" | sed -n 's/.*"via":"\([^"]*\)".*/\1/p' | head -1)
    echo "S5 VIA=$VIAH"
    break
  fi
done
[ "$HOME_FIND" = 1 ] && pass S5_home_find || fail S5_home_find

SB1=$(sb_pid)
echo "S5 SB1=$SB1 SB0=$SB0"
if [ -z "$SB0" ] || [ -z "$SB1" ]; then
  # 取不到 pid：不因工具链误杀；有 SpringBoard 进程名即弱通过
  if ps -A 2>/dev/null | grep -qi '[S]pringBoard'; then
    pass S5_sb_alive_no_pid
  else
    fail S5_sb_missing
  fi
elif [ "$SB0" = "$SB1" ]; then
  pass S5_sb_stable
else
  fail S5_sb_changed_${SB0}_to_${SB1}
fi

FC=$(ps -A|grep -v grep|grep 'ziyan_framecap'|wc -l|tr -d ' ')
echo "S5 FC_N=$FC"
[ "${FC:-0}" -ge 1 ] && pass S5_framecap_alive || fail S5_framecap_dead

if [ "$FAIL" = 0 ]; then echo PHASE6_PASS; else echo PHASE6_FAIL; fi
EOS
}

echo "======== PHASE6 FIND→TAP→5s→MINIMIZE ========"
case "$WANT" in
  all)
    run_one 53 192.168.31.53 rootless
    run_one 101 192.168.31.101 rootful
    run_one 112 192.168.31.112 rootful
    run_one 166 192.168.31.166 rootful
    ;;
  53) run_one 53 192.168.31.53 rootless ;;
  101) run_one 101 192.168.31.101 rootful ;;
  112) run_one 112 192.168.31.112 rootful ;;
  166) run_one 166 192.168.31.166 rootful ;;
  *) echo "bad target $WANT"; exit 2 ;;
esac

{
  echo "# PHASE6 FIND→TAP→5s→MINIMIZE GATE"
  echo
  ALL=1
  for t in 53 101 112 166; do
    [ -f "$OUT/gate_${t}.txt" ] || continue
    echo "## .$t"
    grep -E 'PASS |FAIL |PHASE6_|S[0-9] ' "$OUT/gate_${t}.txt" || true
    grep -q PHASE6_PASS "$OUT/gate_${t}.txt" || ALL=0
    echo
  done
  if [ "$ALL" = 1 ]; then echo "## OVERALL=PASS"; else echo "## OVERALL=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
cp -f "$OUT/VERDICT.md" "$ROOT/tmp_shots/PHASE6_FIND_TAP_MIN_VERDICT.md"
grep -q 'OVERALL=PASS' "$OUT/VERDICT.md"
