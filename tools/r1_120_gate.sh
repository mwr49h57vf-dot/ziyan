#!/bin/bash
# R1-120 自测门禁（修正版）
# 错测反思：旧门禁把「锁屏 relay=0 + 啃冻帧 getColor」当 PASS —— 那是 bug。
# 正确：
#   G1 解锁稳态：pulse 涨；窗口内 serve_force 近 0
#   G2 锁屏：业务不停（pulse 继续涨）；shm seq/ts 变化（找完作废+再截，禁永冻）
#   G3 解锁后稳态：pulse 继续；serve_force 不连打
#   G4 手切模拟：front_bid 翻 10 次，relay/force 风暴有界
set +e
TAG="${1:-dev}"
V="${2:-/usr/lib/ziyan/var}"
LOG="$V/.ziyan_framecap_log"
SHM="$V/.ziyan_frame_shm"

echo "TAG=$TAG"
echo "VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)"
echo "FRONT=$(tr '\n' ' ' < "$V/.ziyan_front_bid" 2>/dev/null)"
echo "EMB=$(test -f "$V/.ziyan_lua_embedded" && echo y || echo n)"
echo "FC=$(ps -A 2>/dev/null | grep -v grep | grep ziyan_framecap | head -1)"

pulse_n() {
  sed -n 's/.*n=\([0-9][0-9]*\).*/\1/p' "$V/.ziyan_find_pulse" 2>/dev/null | head -1
}

read_hdr() {
  # header: magic4 + ver u32 + w u32 + h u32 + bpr u32 + seq u32 + ts u64
  od -An -t u4 -N 28 "$SHM" 2>/dev/null | {
    # shellcheck disable=SC2034
    read -r a b c d e f g || true
  }
  # portable: use dd + hexdump-ish via od lines
  local line
  line=$(od -An -t x1 -N 4 "$SHM" 2>/dev/null | tr -d ' \n')
  if [ "$line" != "5a594652" ]; then
    echo "NO_HDR"
    return
  fi
  # unpack with od unsigned ints: skip magic(4) → 6xu32 then need ts as 2xu32 little
  local vals
  vals=$(od -An -t u4 -j 4 -N 24 "$SHM" 2>/dev/null)
  # vals: ver w h bpr seq ts_lo ts_hi (ts spans 8 bytes = 2xu4)
  set -- $vals
  local ver=$1 w=$2 h=$3 bpr=$4 seq=$5 tslo=$6 tshi=$7
  # approx ts = tslo + tshi*2^32 — print both
  echo "w=$w h=$h seq=$seq tslo=$tslo tshi=$tshi"
}

log_count() {
  local pat=$1
  grep -cE "$pat" "$LOG" 2>/dev/null || echo 0
}

getc() {
  local x=$1 y=$2 n="g$$"
  rm -f "$V/.ziyan_color_rep"
  printf 'getColor\n%s\n%s\n%s\n' "$x" "$y" "$n" >"$V/.ziyan_color_req"
  chmod 666 "$V/.ziyan_color_req" 2>/dev/null
  sleep 0.45
  tr '\n' ' ' <"$V/.ziyan_color_rep" 2>/dev/null
  echo
}

do_lock() {
  if [ -x /usr/bin/notifyutil ]; then
    /usr/bin/notifyutil -p com.apple.springboard.lockdevice
    echo notifyutil
    return
  fi
  if command -v notifyutil >/dev/null 2>&1; then
    notifyutil -p com.apple.springboard.lockdevice
    echo notifyutil
    return
  fi
  if command -v activator >/dev/null 2>&1; then
    activator send libactivator.system.sleepbutton
    echo activator
    return
  fi
  # last resort: ask BackBoard via kill -TSTP? skip
  echo NONE
}

do_wake() {
  notifyutil -p com.apple.springboard.unlockdevice 2>/dev/null
  if command -v activator >/dev/null 2>&1; then
    activator send libactivator.system.homebutton 2>/dev/null
  fi
  uiopen about:blank >/dev/null 2>&1
}

echo "=== G1 STEADY 18s ==="
SF0=$(log_count 'serve_force')
RL0=$(log_count 'relay_req')
P0=$(pulse_n); H0=$(read_hdr); C0=$(getc 120 120)
sleep 18
SF1=$(log_count 'serve_force')
RL1=$(log_count 'relay_req')
P1=$(pulse_n); H1=$(read_hdr); C1=$(getc 120 120)
d1=$((P1 - P0))
dsf=$((SF1 - SF0))
drl=$((RL1 - RL0))
echo "P0=$P0 P1=$P1 DELTA=$d1"
echo "H0=$H0"
echo "H1=$H1"
echo "C0=$C0"
echo "C1=$C1"
echo "serve_force_delta=$dsf relay_delta=$drl"
G1=PASS
[ "$d1" -lt 12 ] && G1=FAIL
# 稳态允许偶发 1～2；连打则 FAIL
[ "$dsf" -gt 3 ] && G1=FAIL
echo "G1_STEADY=$G1"

echo "=== G2 LOCK continues + refresh ==="
PB=$(pulse_n); HB=$(read_hdr); CB=$(getc 200 200)
seqB=$(echo "$HB" | sed -n 's/.*seq=\([0-9]*\).*/\1/p')
tsB=$(echo "$HB" | sed -n 's/.*tslo=\([0-9]*\).*/\1/p')
SFB=$(log_count 'serve_force')
LOCK_VIA=$(do_lock)
echo "LOCK_VIA=$LOCK_VIA"
sleep 1
echo "AFTER_LOCK_HDR=$(read_hdr)"
sleep 8
PA=$(pulse_n); HA=$(read_hdr); CA=$(getc 200 200)
dLock=$((PA - PB))
seqA=$(echo "$HA" | sed -n 's/.*seq=\([0-9]*\).*/\1/p')
tsA=$(echo "$HA" | sed -n 's/.*tslo=\([0-9]*\).*/\1/p')
SFA=$(log_count 'serve_force')
echo "PB=$PB PA=$PA PULSE_LOCK_DELTA=$dLock"
echo "HB=$HB"
echo "HA=$HA"
echo "CB=$CB"
echo "CA=$CA"
echo "serve_force_during_lock=$((SFA - SFB))"
G2_PULSE=FAIL
[ "$dLock" -ge 5 ] && G2_PULSE=PASS
G2_REFRESH=FAIL
if [ -n "$seqA" ] && [ -n "$seqB" ] && [ "$seqA" != "$seqB" ]; then
  G2_REFRESH=PASS
fi
if [ -n "$tsA" ] && [ -n "$tsB" ] && [ "$tsA" != "$tsB" ]; then
  G2_REFRESH=PASS
fi
# 若锁屏工具不可用：仍要求解锁态下多次 find 后 seq/ts 变化（G2b）
if [ "$LOCK_VIA" = "NONE" ]; then
  echo "LOCK_UNAVAILABLE → G2b unlock refresh probe"
  HX0=$(read_hdr)
  sleep 3
  HX1=$(read_hdr)
  sx0=$(echo "$HX0" | sed -n 's/.*seq=\([0-9]*\).*/\1/p')
  sx1=$(echo "$HX1" | sed -n 's/.*seq=\([0-9]*\).*/\1/p')
  tx0=$(echo "$HX0" | sed -n 's/.*tslo=\([0-9]*\).*/\1/p')
  tx1=$(echo "$HX1" | sed -n 's/.*tslo=\([0-9]*\).*/\1/p')
  echo "HX0=$HX0 HX1=$HX1"
  G2_PULSE=PASS
  [ "$d1" -ge 12 ] || G2_PULSE=FAIL
  G2_REFRESH=FAIL
  [ "$sx0" != "$sx1" ] && G2_REFRESH=PASS
  [ "$tx0" != "$tx1" ] && G2_REFRESH=PASS
fi
echo "G2_PULSE=$G2_PULSE G2_REFRESH=$G2_REFRESH"
do_wake
sleep 2

echo "=== G3 POST-WAKE STEADY 12s ==="
SF2=$(log_count 'serve_force')
P2=$(pulse_n)
sleep 12
SF3=$(log_count 'serve_force')
P3=$(pulse_n)
d3=$((P3 - P2))
dsf3=$((SF3 - SF2))
echo "PULSE_DELTA=$d3 serve_force_delta=$dsf3"
G3=PASS
[ "$d3" -lt 8 ] && G3=FAIL
[ "$dsf3" -gt 4 ] && G3=FAIL
echo "G3_STEADY=$G3"

echo "=== G4 BID FLIP 10x ==="
BID0=$(tr '\n' ' ' <"$V/.ziyan_front_bid" 2>/dev/null)
RLB=$(log_count 'relay_req|home_force_recap|front_bid_chg')
SFB4=$(log_count 'serve_force')
i=0
while [ "$i" -lt 10 ]; do
  i=$((i + 1))
  if [ $((i % 2)) -eq 0 ]; then
    printf 'com.apple.springboard\n' >"$V/.ziyan_front_bid"
  else
    printf 'com.xztl.ios\n' >"$V/.ziyan_front_bid"
  fi
  chmod 666 "$V/.ziyan_front_bid" 2>/dev/null
  sleep 0.4
done
sleep 2
RLA=$(log_count 'relay_req|home_force_recap|front_bid_chg')
SFA4=$(log_count 'serve_force')
ESTORM=$((RLA - RLB + SFA4 - SFB4))
echo "BID0=$BID0 ESTORM=$ESTORM (relay/force/bid_chg window)"
# restore game bid hint
printf 'com.xztl.ios\n' >"$V/.ziyan_front_bid" 2>/dev/null
G4=PASS
[ "$ESTORM" -gt 28 ] && G4=FAIL
echo "G4_HAND=$G4"

OVERALL=PASS
[ "$G1" != PASS ] && OVERALL=FAIL
[ "$G2_PULSE" != PASS ] && OVERALL=FAIL
[ "$G2_REFRESH" != PASS ] && OVERALL=FAIL
[ "$G3" != PASS ] && OVERALL=FAIL
[ "$G4" != PASS ] && OVERALL=FAIL
echo "=== SUMMARY ==="
echo "G1=$G1 G2_PULSE=$G2_PULSE G2_REFRESH=$G2_REFRESH G3=$G3 G4=$G4"
echo "OVERALL=$OVERALL"
