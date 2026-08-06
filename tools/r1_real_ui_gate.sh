#!/bin/bash
# R1 真机 UI 门禁（对齐人工采集：真 Home / 真锁屏 / 真切画面）
# 用法：r1_real_ui_gate.sh <tag> <VAR> <game_bid> <game_url>
# 依赖：.ziyan_go_home / .ziyan_lock_req / .ziyan_unlock_req / uiopen
set +e
TAG="${1:-dev}"
V="${2:-/usr/lib/ziyan/var}"
GAME_BID="${3:-com.xztl.ios}"
GAME_URL="${4:-xztl://}"
LOG="$V/.ziyan_framecap_log"
SHM="$V/.ziyan_frame_shm"
UIO=$(ls /var/jb/usr/bin/uiopen /usr/bin/uiopen 2>/dev/null | head -1)

echo "TAG=$TAG"
echo "VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)"
echo "GAME_BID=$GAME_BID GAME_URL=$GAME_URL UIO=$UIO"
echo "FRONT0=$(tr '\n' ' ' <"$V/.ziyan_front_bid" 2>/dev/null)"

FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

pulse_n() {
  sed -n 's/.*n=\([0-9][0-9]*\).*/\1/p' "$V/.ziyan_find_pulse" 2>/dev/null | head -1
}
read_seq() {
  local line vals
  line=$(od -An -t x1 -N 4 "$SHM" 2>/dev/null | tr -d ' \n')
  [ "$line" = "5a594652" ] || { echo 0; return; }
  vals=$(od -An -t u4 -j 20 -N 4 "$SHM" 2>/dev/null)
  echo ${vals:-0}
}
cksum_pix() {
  dd if="$SHM" bs=1 skip=64 count=65536 2>/dev/null | cksum | cut -d' ' -f1
}
front() { tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null; }
shm_bid() { tr -d '\r\n' <"$V/.ziyan_shm_front_bid" 2>/dev/null; }

do_unlock() {
  rm -f "$V/.ziyan_unlock_rep" "$V/.ziyan_display_locked"
  echo 1 >"$V/.ziyan_unlock_req"
  chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
  sleep 1.5
}
do_home() {
  rm -f "$V/.ziyan_go_home"
  echo 1 >"$V/.ziyan_go_home"
  chmod 666 "$V/.ziyan_go_home"
  local t
  for t in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    f=$(front)
    [ "$f" = "com.apple.springboard" ] && return 0
  done
  return 1
}
do_open_game() {
  [ -n "$UIO" ] || return 1
  local t f
  for t in 1 2 3 4 5 6; do
    "$UIO" "$GAME_URL" >/dev/null 2>&1
    sleep 0.8
    f=$(front)
    [ "$f" = "$GAME_BID" ] && return 0
  done
  # 备用 scheme（xztl / 包名 URL）
  for u in "com.xztl.ios://" "xztl://" "xqhyios://" "v3://"; do
    "$UIO" "$u" >/dev/null 2>&1
    sleep 1.0
    f=$(front)
    [ "$f" = "$GAME_BID" ] && return 0
  done
  return 1
}
do_open_prefs() {
  [ -n "$UIO" ] || return 1
  "$UIO" "prefs:root=General" >/dev/null 2>&1
  local t
  for t in 1 2 3 4 5 6 7 8; do
    sleep 0.35
    f=$(front)
    echo "$f" | grep -qi Preferences && return 0
  done
  return 1
}
do_lock() {
  mkdir -p "$V" 2>/dev/null
  # 125d：禁止门禁自写 display_locked（假锁）；须 SB 真 isUILocked
  rm -f "$V/.ziyan_lock_rep" "$V/.ziyan_lock_state" "$V/.ziyan_display_locked"
  echo 1 >"$V/.ziyan_lock_req"
  chmod 666 "$V/.ziyan_lock_req" 2>/dev/null
  local t
  for t in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.35
    if grep -q '^ok' "$V/.ziyan_lock_rep" 2>/dev/null &&
      grep -q 'isUILocked=1' "$V/.ziyan_lock_rep" 2>/dev/null; then
      return 0
    fi
  done
  # 兼容旧包：仅有 ok 但无 isUILocked 行 → 仍失败（防假 ok）
  echo "lock_rep=$(tr '\n' ' ' <"$V/.ziyan_lock_rep" 2>/dev/null)"
  return 1
}

wait_pix_change() {
  local before=$1 max=${2:-12}
  local t c
  for t in $(seq 1 "$max"); do
    sleep 0.35
    c=$(cksum_pix)
    [ -n "$c" ] && [ "$c" != "$before" ] && return 0
  done
  return 1
}

echo "=== G0 READY (embed pulse↑ + framecap) ==="
do_unlock
ok0=0
for attempt in 1 2 3; do
  P0=$(pulse_n); sleep 3; P1=$(pulse_n)
  d0=$((P1 - P0))
  fc=$(ps -A | grep -v grep | grep 'ziyan_framecap serve' | wc -l | tr -d ' ')
  echo "g0_try$attempt pulse $P0->$P1 delta=$d0 fc=$fc"
  if [ "$d0" -ge 2 ] && [ "$fc" -ge 1 ]; then ok0=1; break; fi
  echo nonce=g0_$attempt >"$V/.ziyan_embed_go" 2>/dev/null
  sleep 2
done
[ "$ok0" = 1 ] && pass G0 || fail G0_pulse_stale

echo "=== G1 OPEN GAME ==="
do_open_game
sleep 1.2
FG=$(front); SB=$(shm_bid); CK=$(cksum_pix); SQ=$(read_seq)
echo "game front=$FG shm=$SB seq=$SQ ck=$CK"
if [ "$FG" = "$GAME_BID" ]; then pass G1_front; else fail "G1_front_$FG"; fi
# 给合帧时间对齐 shm 戳
for t in 1 2 3 4 5 6 7 8; do
  sleep 0.4
  SB=$(shm_bid)
  [ "$SB" = "$GAME_BID" ] && break
done
SB=$(shm_bid)
[ "$SB" = "$GAME_BID" ] && pass G1_shm || fail "G1_shm_$SB"

echo "=== G2 REAL HOME×4（像素必须变，禁卡游戏图） ==="
HOME_OK=0
HOME_FAIL=0
i=0
while [ "$i" -lt 4 ]; do
  i=$((i + 1))
  do_open_game >/dev/null 2>&1
  sleep 0.8
  CKB=$(cksum_pix); SQB=$(read_seq); FGB=$(front)
  do_home
  FH=$(front)
  changed=0
  if wait_pix_change "$CKB" 14; then changed=1; fi
  CKA=$(cksum_pix); SQA=$(read_seq); SBH=$(shm_bid)
  echo "home$i front=$FGB->$FH shm=$SBH seq=$SQB->$SQA ck=$CKB->$CKA changed=$changed"
  if [ "$FH" = "com.apple.springboard" ] && [ "$changed" = 1 ]; then
    HOME_OK=$((HOME_OK + 1))
  else
    HOME_FAIL=$((HOME_FAIL + 1))
  fi
  # shm 戳最终应对齐桌面（允许短暂延迟）
  for t in 1 2 3 4 5 6; do
    sleep 0.3
    [ "$(shm_bid)" = "com.apple.springboard" ] && break
  done
done
echo "HOME_OK=$HOME_OK HOME_FAIL=$HOME_FAIL"
if [ "$HOME_OK" -ge 3 ] && [ "$HOME_FAIL" -le 1 ]; then pass G2; else fail G2_home_freeze; fi

echo "=== G3 SWITCH PREFS↔GAME×3 ==="
# 125d：前台必须真切；画面证据=像素变 或 shm_front_bid 对齐（禁卡死旧图）
SW_OK=0
SW_FAIL=0
i=0
while [ "$i" -lt 3 ]; do
  i=$((i + 1))
  do_open_game >/dev/null 2>&1; sleep 0.8
  CKB=$(cksum_pix)
  do_open_prefs
  FP=$(front)
  ch1=0; wait_pix_change "$CKB" 14 && ch1=1
  SB1=$(shm_bid)
  echo "$SB1" | grep -qi Preferences && ch1=1
  CKP=$(cksum_pix)
  do_open_game
  FG=$(front)
  ch2=0; wait_pix_change "$CKP" 14 && ch2=1
  SB2=$(shm_bid)
  [ "$SB2" = "$GAME_BID" ] && ch2=1
  echo "sw$i prefs=$FP shm1=$SB1 ch1=$ch1 game=$FG shm2=$SB2 ch2=$ch2"
  if echo "$FP" | grep -qi Preferences && [ "$FG" = "$GAME_BID" ] && [ "$ch1$ch2" = "11" ]; then
    SW_OK=$((SW_OK + 1))
  else
    SW_FAIL=$((SW_FAIL + 1))
  fi
done
echo "SW_OK=$SW_OK SW_FAIL=$SW_FAIL"
if [ "$SW_OK" -ge 2 ]; then pass G3; else fail G3_switch_freeze; fi

echo "=== G4 REAL LOCK 8s（须 isUILocked + 像素变；禁假 display_locked） ==="
do_open_game >/dev/null 2>&1; sleep 1
CKB=$(cksum_pix); SQB=$(read_seq); PB=$(pulse_n)
if do_lock; then
  sleep 8
  CKA=$(cksum_pix); SQA=$(read_seq); PA=$(pulse_n)
  dL=$((PA - PB))
  echo "lock_rep=$(tr '\n' ' ' <"$V/.ziyan_lock_rep" 2>/dev/null)"
  echo "lock pulse=$PB->$PA delta=$dL seq=$SQB->$SQA ck=$CKB->$CKA"
  G4=1
  # 真锁后合帧应变（黑屏/锁屏墙纸）或 seq 前进；二者皆不变则假锁
  if [ "$SQA" = "$SQB" ] && [ "$CKA" = "$CKB" ]; then G4=0; fi
  # pulse 在锁屏仍应前进（业务找色循环）；过低仅告警不单杀（部分机锁后节流）
  [ "$dL" -ge 1 ] || echo "WARN G4_pulse_low delta=$dL"
  [ "$G4" = 1 ] && pass G4 || fail G4_lock_freeze
else
  fail G4_lock_req
fi

echo "=== G5 UNLOCK BACK TO GAME ==="
do_unlock
rm -f "$V/.ziyan_display_locked"
CKB=$(cksum_pix)
# 解锁后可能 embed 重启：先回游戏再等 pulse 恢复
do_open_game || true
sleep 2
echo nonce=g5_$$ >"$V/.ziyan_embed_go" 2>/dev/null
chmod 666 "$V/.ziyan_embed_go" 2>/dev/null
G5=0
for t in 1 2 3 4 5 6; do
  FG=$(front)
  PB=$(pulse_n); sleep 2; PA=$(pulse_n)
  d5=$((PA - PB))
  echo "g5_try$t front=$FG pulse=$PB->$PA delta=$d5"
  if [ "$FG" = "$GAME_BID" ] && [ "$d5" -ge 2 ]; then G5=1; break; fi
  do_open_game >/dev/null 2>&1 || true
done
FG=$(front); SB=$(shm_bid)
echo "back front=$FG shm=$SB"
[ "$G5" = 1 ] && pass G5 || fail G5_back
# 像素：相对锁屏变，或已在游戏且 shm 对齐即可
if wait_pix_change "$CKB" 8 || { [ "$FG" = "$GAME_BID" ] && [ "$(shm_bid)" = "$GAME_BID" ]; }; then
  pass G5_pix
else
  fail G5_pix_stuck
fi

echo "=== G6 POST STEADY 10s ==="
# 若 unlock 打挂了 embed，先轻推；pulse 回绕/重启时再测一轮
echo nonce=g6_$$ >"$V/.ziyan_embed_go" 2>/dev/null
sleep 2
SF0=$(grep -cE 'serve_force|home_force' "$LOG" 2>/dev/null); SF0=${SF0:-0}
P0=$(pulse_n); sleep 10; P1=$(pulse_n)
SF1=$(grep -cE 'serve_force|home_force' "$LOG" 2>/dev/null); SF1=${SF1:-0}
d6=$((P1 - P0)); dsf=$((SF1 - SF0))
echo "pulse_delta=$d6 force_delta=$dsf p=$P0->$P1"
if [ "$d6" -lt 5 ]; then
  echo nonce=g6r_$$ >"$V/.ziyan_embed_go" 2>/dev/null
  sleep 2
  P0=$(pulse_n); sleep 8; P1=$(pulse_n)
  d6=$((P1 - P0))
  echo "g6_retry pulse_delta=$d6 p=$P0->$P1"
fi
if [ "$d6" -ge 5 ] && [ "$dsf" -le 40 ]; then pass G6; else fail G6_post; fi

echo "=== SUMMARY ==="
echo "FAILS=$FAILS"
if [ "$FAILS" -eq 0 ]; then
  echo "OVERALL=PASS"
  exit 0
fi
echo "OVERALL=FAIL"
exit 1
