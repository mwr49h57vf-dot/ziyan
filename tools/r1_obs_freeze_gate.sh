#!/bin/bash
# 采集同节奏 OBS 门禁：对标 .171「滑动/Home/锁屏都不卡图」
# 阶段：G0 就绪 → G1 稳态 20s → G2 Home×8 → G3 锁屏 10s → G4 回游戏 → G5 风暴有界
set +e
TAG="${1:-dev}"
V="${2:-/usr/lib/ziyan/var}"
LOG="$V/.ziyan_framecap_log"
SHM="$V/.ziyan_frame_shm"
# 游戏 bid：优先参数3 / 环境 GAME_BID / 当前 front_bid；禁写死导致 .53 异包名假 FAIL
GAME_BID="${3:-${GAME_BID:-}}"
if [ -z "$GAME_BID" ]; then
  GAME_BID=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
fi
if [ -z "$GAME_BID" ] || [ "$GAME_BID" = "com.apple.springboard" ]; then
  GAME_BID="com.xztl.ios"
fi

echo "TAG=$TAG"
echo "VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)"
echo "GAME_BID=$GAME_BID"
echo "FRONT0=$(tr '\n' ' ' <"$V/.ziyan_front_bid" 2>/dev/null)"
echo "SHM_BID0=$(tr '\n' ' ' <"$V/.ziyan_shm_front_bid" 2>/dev/null)"

lc() {
  local n
  n=$(grep -cE "$1" "$LOG" 2>/dev/null)
  echo "${n:-0}"
}
pulse_n() {
  local n
  n=$(sed -n 's/.*n=\([0-9][0-9]*\).*/\1/p' "$V/.ziyan_find_pulse" 2>/dev/null | head -1)
  echo "${n:-0}"
}
read_seq() {
  local line vals
  line=$(od -An -t x1 -N 4 "$SHM" 2>/dev/null | tr -d ' \n')
  [ "$line" = "5a594652" ] || { echo 0; return; }
  vals=$(od -An -t u4 -j 20 -N 4 "$SHM" 2>/dev/null)
  echo ${vals:-0}
}
cksum_pix() {
  dd if="$SHM" bs=1 skip=64 count=8192 2>/dev/null | cksum | cut -d' ' -f1
}
set_bid() {
  printf '%s\n' "$1" >"$V/.ziyan_front_bid"
  chmod 666 "$V/.ziyan_front_bid" 2>/dev/null
}

FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

echo "=== G0 READY ==="
# 允许一次 embed 重启噪声：取 2 段增长
ok0=0
for attempt in 1 2 3; do
  P0=$(pulse_n); sleep 3; P1=$(pulse_n)
  d0=$((P1 - P0))
  fc=$(ps -A|grep -v grep|grep 'ziyan_framecap serve'|wc -l|tr -d ' ')
  echo "g0_try$attempt pulse $P0->$P1 delta=$d0 fc=$fc"
  if [ "$d0" -ge 2 ] && [ "$fc" -ge 1 ]; then ok0=1; break; fi
  # 轻推 embed
  echo nonce=g0_$attempt >"$V/.ziyan_embed_go" 2>/dev/null
  sleep 2
done
if [ "$ok0" = 1 ]; then pass G0; else fail "G0_pulse_stale"; fi

echo "=== G1 STEADY 20s (serve_force≈0, pulse↑) ==="
SF0=$(lc 'serve_force')
RL0=$(lc 'relay_req')
PS0=$(pulse_n); CK0=$(cksum_pix); SQ0=$(read_seq)
sleep 20
SF1=$(lc 'serve_force'); RL1=$(lc 'relay_req')
PS1=$(pulse_n); CK1=$(cksum_pix); SQ1=$(read_seq)
d1=$((PS1 - PS0)); dsf=$((SF1 - SF0)); drl=$((RL1 - RL0))
echo "pulse_delta=$d1 serve_force_delta=$dsf relay_delta=$drl seq=$SQ0->$SQ1 ck=$CK0->$CK1"
if [ "$d1" -ge 12 ] && [ "$dsf" -le 4 ]; then pass G1; else fail "G1_steady"; fi

echo "=== G2 HOME×8 (每切必须换帧，禁卡游戏图) ==="
# 先确保在游戏 bid
set_bid "$GAME_BID"
sleep 1.2
HOME_OK=0
HOME_FAIL=0
STORM0=$(lc 'relay_req|home_force|front_bid_chg|serve_force')
i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  if [ $((i % 2)) -eq 1 ]; then
    # → Home
    SQB=$(read_seq); CKB=$(cksum_pix); BIDB=$(tr '\n' ' ' <"$V/.ziyan_shm_front_bid" 2>/dev/null)
    set_bid com.apple.springboard
    # 等合帧（最多 2s）
    changed=0
    for t in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.2
      SQA=$(read_seq); CKA=$(cksum_pix); BIDA=$(tr '\n' ' ' <"$V/.ziyan_shm_front_bid" 2>/dev/null)
      # 换帧：seq 变 或 cksum 变；且 shm 戳应变 springboard（或至少不再是纯游戏冻）
      if [ "$SQA" != "$SQB" ] || [ "$CKA" != "$CKB" ]; then
        changed=1
        break
      fi
    done
    echo "home$i seq=$SQB->$SQA ck=$CKB->$CKA shm_bid='$BIDA' changed=$changed"
    if [ "$changed" = 1 ]; then HOME_OK=$((HOME_OK + 1)); else HOME_FAIL=$((HOME_FAIL + 1)); fi
  else
    # → Game
    SQB=$(read_seq); CKB=$(cksum_pix)
    set_bid "$GAME_BID"
    changed=0
    for t in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.2
      SQA=$(read_seq); CKA=$(cksum_pix)
      if [ "$SQA" != "$SQB" ] || [ "$CKA" != "$CKB" ]; then
        changed=1
        break
      fi
    done
    echo "app$i seq=$SQB->$SQA ck=$CKB->$CKA changed=$changed"
    if [ "$changed" = 1 ]; then HOME_OK=$((HOME_OK + 1)); else HOME_FAIL=$((HOME_FAIL + 1)); fi
  fi
done
STORM1=$(lc 'relay_req|home_force|front_bid_chg|serve_force')
ESTORM=$((STORM1 - STORM0))
echo "HOME_OK=$HOME_OK HOME_FAIL=$HOME_FAIL ESTORM=$ESTORM"
# 8 次切换至少 6 次换帧；风暴 ≤40（含 paced）
if [ "$HOME_OK" -ge 6 ] && [ "$HOME_FAIL" -le 2 ] && [ "$ESTORM" -le 40 ]; then
  pass G2
else
  fail "G2_home_freeze_or_storm"
fi

echo "=== G3 LOCK 10s (业务不停 + 非冻游戏帧) ==="
set_bid "$GAME_BID"
sleep 1
rm -f "$V/.ziyan_display_locked"
SQB=$(read_seq); CKB=$(cksum_pix); PB=$(pulse_n)
printf '1\n' >"$V/.ziyan_display_locked"
chmod 666 "$V/.ziyan_display_locked"
sleep 10
SQA=$(read_seq); CKA=$(cksum_pix); PA=$(pulse_n)
dL=$((PA - PB))
echo "lock pulse=$PB->$PA delta=$dL seq=$SQB->$SQA ck=$CKB->$CKA"
G3=1
[ "$dL" -ge 6 ] || G3=0
if [ "$SQA" = "$SQB" ] && [ "$CKA" = "$CKB" ]; then G3=0; fi
rm -f "$V/.ziyan_display_locked"
if [ "$G3" = 1 ]; then pass G3; else fail "G3_lock_freeze"; fi

echo "=== G4 BACK TO GAME ==="
set_bid "$GAME_BID"
SQB=$(read_seq); CKB=$(cksum_pix); PB=$(pulse_n)
sleep 3
SQA=$(read_seq); CKA=$(cksum_pix); PA=$(pulse_n)
d4=$((PA - PB))
echo "back pulse_delta=$d4 seq=$SQB->$SQA ck=$CKB->$CKA"
if [ "$d4" -ge 2 ]; then pass G4; else fail "G4_back_dead"; fi

echo "=== G5 POST STEADY 12s ==="
SF2=$(lc 'serve_force'); P2=$(pulse_n)
sleep 12
SF3=$(lc 'serve_force'); P3=$(pulse_n)
d5=$((P3 - P2)); dsf5=$((SF3 - SF2))
echo "pulse_delta=$d5 serve_force_delta=$dsf5"
if [ "$d5" -ge 6 ] && [ "$dsf5" -le 5 ]; then pass G5; else fail "G5_post"; fi

echo "=== SUMMARY ==="
echo "FAILS=$FAILS"
if [ "$FAILS" -eq 0 ]; then
  echo "OVERALL=PASS"
else
  echo "OVERALL=FAIL"
fi
