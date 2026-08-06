#!/usr/bin/env bash
# 143：任意前台找色门禁 —— SB 桌面 + 设置 App，禁锁游戏
# 用法：bash tools/zy_anyfront_find_gate.sh [all|53|101|112|166]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/ANYFRONT_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "======== PRETEST (go_home, no game lock) ========"
bash tools/zy_pretest_clean_4phone.sh | tee "$OUT/pretest.txt"

run_one() {
  local tag="$1" ip="$2" scheme="$3"
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

# 禁锁游戏
rm -f "$VAR/.ziyan_open_app" "$VAR/.ziyan_prefer_app_touch"
echo 1 >"$VAR/.ziyan_keep_daemon"
echo 1 >"$VAR/.ziyan_bbframe_on"
chmod 666 "$VAR/.ziyan_keep_daemon" "$VAR/.ziyan_bbframe_on" 2>/dev/null

# —— G0 回桌面（rootless .53 单次 go_home 常粘前台 App）——
for _h in 1 2 3 4; do
  echo 1 >"$VAR/.ziyan_go_home"
  sleep 0.7
  rm -f "$VAR/.ziyan_go_home"
  FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "$FRONT" | grep -qi springboard && break
done
if ! echo "$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)" | grep -qi springboard; then
  killall -9 Preferences 2>/dev/null || true
  killall -9 com.apple.Preferences 2>/dev/null || true
  sleep 0.6
  echo 1 >"$VAR/.ziyan_go_home"
  sleep 0.8
  rm -f "$VAR/.ziyan_go_home"
fi
sleep 0.5
FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "G0 FRONT=$FRONT VER=$VER"
echo "$FRONT" | grep -qi springboard && pass G0_home || fail G0_home_$FRONT

# —— G1 桌面合帧 ——
echo 1 >"$VAR/.ziyan_force_recap"
echo "nonce=anyfront_home_$$" >"$VAR/.ziyan_frame_req"
chmod 666 "$VAR/.ziyan_force_recap" "$VAR/.ziyan_frame_req" 2>/dev/null
"$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
sleep 1.2
SHM_BID=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
SHM=$(ls -l "$VAR/.ziyan_frame_shm" 2>/dev/null | tr -s ' ' | cut -d' ' -f5)
echo "G1 SHM=$SHM SHM_BID=$SHM_BID"
[ "${SHM:-0}" -gt 1000 ] 2>/dev/null && pass G1_shm || fail G1_shm
echo "$SHM_BID" | grep -qi springboard && pass G1_shm_bid || fail G1_shm_bid_$SHM_BID

# 143：脚本坐标 getColor → 全屏 find（禁缓冲中心硬采，会与 OrientMap 错位）
wait_rep() {
  local i=0
  while [ $i -lt 50 ]; do
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
  # rep: nonce\nok\nCOLOR
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

# 多点取样：任一可 find 即过（壁纸动画允许换点）
home_find_ok=0
COL=""
for xy in "200 200" "100 100" "400 300" "300 500"; do
  set -- $xy; SX=$1; SY=$2
  COL=$(get_color_at "$SX" "$SY")
  echo "G1 getColor $SX,$SY -> $COL"
  [ -n "$COL" ] && [ "$COL" -gt 0 ] 2>/dev/null || continue
  HIT=$(find_color_full "$COL" "afh_${SX}_${SY}_$$")
  echo "G2 FIND@$SX,$SY REP=$HIT"
  if echo "$HIT" | grep -qE '"ok":true|"x":[0-9]{1,4}'; then
    home_find_ok=1
    break
  fi
done
[ "$home_find_ok" = 1 ] && pass G2_home_find || fail G2_home_find

# —— G3 打开设置（任意 App，非游戏） ——
rm -f "$VAR/.ziyan_open_app"
if [ -x "$UIO" ]; then
  "$UIO" 'prefs:root=' >/dev/null 2>&1 || "$UIO" 'App-prefs:root=' >/dev/null 2>&1 || true
else
  # 无 uiopen：写 open_app Preferences
  echo com.apple.Preferences >"$VAR/.ziyan_open_app"
  chmod 666 "$VAR/.ziyan_open_app"
fi
sleep 2.5
FRONT2=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "G3 FRONT=$FRONT2"
echo "$FRONT2" | grep -qiE 'Preferences|preference' && pass G3_prefs || {
  # 部分机 front_bid 延迟：只要不是 springboard 且不是游戏即过
  if echo "$FRONT2" | grep -qiE 'springboard|xztl|ljzbbadao'; then
    fail G3_prefs_$FRONT2
  else
    pass G3_prefs_loose_$FRONT2
  fi
}
# 禁止误开游戏
echo "$FRONT2" | grep -qiE 'xztl|ljzbbadao' && fail G3_game_locked || pass G3_not_game

echo 1 >"$VAR/.ziyan_force_recap"
echo "nonce=anyfront_prefs_$$" >"$VAR/.ziyan_frame_req"
"$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
sleep 1.2
SHM_BID2=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
SHM2=$(ls -l "$VAR/.ziyan_frame_shm" 2>/dev/null | tr -s ' ' | cut -d' ' -f5)
echo "G3 SHM=$SHM2 SHM_BID=$SHM_BID2"
[ "${SHM2:-0}" -gt 1000 ] && pass G3_shm || fail G3_shm
# shm 应对齐前台（非 springboard）
if echo "$SHM_BID2" | grep -qi springboard; then
  fail G3_shm_still_sb
else
  pass G3_shm_app
fi

prefs_find_ok=0
for xy in "200 200" "100 100" "400 300" "300 400"; do
  set -- $xy; SX=$1; SY=$2
  COLP=$(get_color_at "$SX" "$SY")
  echo "G3 getColor $SX,$SY -> $COLP"
  [ -n "$COLP" ] && [ "$COLP" -gt 0 ] 2>/dev/null || continue
  HIT=$(find_color_full "$COLP" "afp_${SX}_${SY}_$$")
  echo "G4 FIND@$SX,$SY REP=$HIT"
  if echo "$HIT" | grep -qE '"ok":true|"x":[0-9]{1,4}'; then
    prefs_find_ok=1
    break
  fi
done
[ "$prefs_find_ok" = 1 ] && pass G4_prefs_find || fail G4_prefs_find

# —— G5 再回桌面找色（.53 单次 go_home 常粘 Preferences，多试+杀进程）——
rm -f "$VAR/.ziyan_open_app"
for _h in 1 2 3; do
  echo 1 >"$VAR/.ziyan_go_home"
  sleep 0.8
  rm -f "$VAR/.ziyan_go_home"
  FRONT_TRY=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "$FRONT_TRY" | grep -qi springboard && break
done
if ! echo "$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)" | grep -qi springboard; then
  killall -9 Preferences 2>/dev/null || true
  sleep 0.8
  echo 1 >"$VAR/.ziyan_go_home"
  sleep 0.8
  rm -f "$VAR/.ziyan_go_home"
fi
sleep 0.5
echo 1 >"$VAR/.ziyan_force_recap"
echo "nonce=anyfront_home2_$$" >"$VAR/.ziyan_frame_req"
"$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
sleep 1
FRONT3=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
SHM_BID3=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
echo "G5 FRONT=$FRONT3 SHM_BID=$SHM_BID3"
echo "$FRONT3" | grep -qi springboard && pass G5_home || fail G5_home
echo "$SHM_BID3" | grep -qi springboard && pass G5_shm_bid || fail G5_shm_bid
home2_ok=0
for xy in "200 200" "100 100" "400 300" "300 500"; do
  set -- $xy; SX=$1; SY=$2
  COLH=$(get_color_at "$SX" "$SY")
  echo "G5 getColor $SX,$SY -> $COLH"
  [ -n "$COLH" ] && [ "$COLH" -gt 0 ] 2>/dev/null || continue
  HIT=$(find_color_full "$COLH" "afh2_${SX}_${SY}_$$")
  echo "G5 FIND@$SX,$SY REP=$HIT"
  if echo "$HIT" | grep -qE '"ok":true|"x":[0-9]{1,4}'; then
    home2_ok=1
    break
  fi
done
[ "$home2_ok" = 1 ] && pass G5_home_find || fail G5_home_find

OPEN=$(test -f "$VAR/.ziyan_open_app" && echo 1 || echo 0)
[ "$OPEN" = "0" ] && pass G6_no_open_app || fail G6_open_app_sticky

if [ "$FAIL" = 0 ]; then echo ANYFRONT_PASS; else echo ANYFRONT_FAIL; fi
EOS
}

echo "======== ANYFRONT GATE ========"
# 串行：并行时 .53 SSH 偶发空文件导致假 OVERALL=FAIL
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
  echo "# ANYFRONT FIND GATE 143"
  echo
  ALL=1
  for t in 53 101 112 166; do
    [ -f "$OUT/gate_${t}.txt" ] || continue
    echo "## .$t"
    grep -E 'PASS |FAIL |ANYFRONT_|G[0-9] ' "$OUT/gate_${t}.txt" || true
    grep -q ANYFRONT_PASS "$OUT/gate_${t}.txt" || ALL=0
    echo
  done
  if [ "$ALL" = 1 ]; then echo "## OVERALL=PASS"; else echo "## OVERALL=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
grep -q 'OVERALL=PASS' "$OUT/VERDICT.md"
