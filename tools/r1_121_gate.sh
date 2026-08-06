#!/bin/bash
# R1-121 门禁（自我反思修订）
# 错测：120 只看 ts 变 / relay=0 → 假 PASS（CARender 失败仍啃冻帧）
# 正解：
#   G1 稳态 pulse 涨 + serve_force≈0
#   G2 模拟锁屏：seq 必变 或 像素 cksum 变（禁冻游戏帧）
#   G3 解锁后稳态
#   G4 bid 翻 10 次风暴有界
set +e
TAG="${1:-dev}"
V="${2:-/usr/lib/ziyan/var}"
LOG="$V/.ziyan_framecap_log"
SHM="$V/.ziyan_frame_shm"

echo "TAG=$TAG"
echo "VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)"
echo "FRONT=$(tr '\n' ' ' <"$V/.ziyan_front_bid" 2>/dev/null)"
echo "EMB=$(test -f "$V/.ziyan_lua_embedded" && echo y || echo n)"

lc() {
  # grep -c 无匹配时 exit=1，禁 || echo 造成 0\n0
  local n
  n=$(grep -cE "$1" "$LOG" 2>/dev/null)
  n=${n:-0}
  echo "$n"
}
pulse_n() {
  local n
  n=$(sed -n 's/.*n=\([0-9][0-9]*\).*/\1/p' "$V/.ziyan_find_pulse" 2>/dev/null | head -1)
  echo "${n:-0}"
}
read_hdr() {
  local line
  line=$(od -An -t x1 -N 4 "$SHM" 2>/dev/null | tr -d ' \n')
  if [ "$line" != "5a594652" ]; then
    echo "NO_HDR"
    return
  fi
  local vals
  vals=$(od -An -t u4 -j 4 -N 24 "$SHM" 2>/dev/null)
  set -- $vals
  echo "w=$2 h=$3 seq=$5 tslo=$6 rel=$(od -An -t u1 -j 40 -N 1 "$SHM" 2>/dev/null | tr -d ' ')"
}
cksum_pix() {
  # 头 64B 后 8KB
  dd if="$SHM" bs=1 skip=64 count=8192 2>/dev/null | cksum | cut -d' ' -f1
}

echo "=== G1 STEADY 15s ==="
SF0=$(lc 'serve_force')
P0=$(pulse_n)
H0=$(read_hdr)
CK0=$(cksum_pix)
sleep 15
SF1=$(lc 'serve_force')
P1=$(pulse_n)
H1=$(read_hdr)
CK1=$(cksum_pix)
d1=$((P1 - P0))
dsf=$((SF1 - SF0))
echo "P0=$P0 P1=$P1 DELTA=$d1 serve_force_delta=$dsf"
echo "H0=$H0 H1=$H1 CK0=$CK0 CK1=$CK1"
G1=PASS
[ "$d1" -lt 10 ] && G1=FAIL
[ "$dsf" -gt 4 ] && G1=FAIL
echo "G1_STEADY=$G1"

echo "=== G2 SIM LOCK (display_locked=1) ==="
# 采样解锁态
rm -f "$V/.ziyan_display_locked"
sleep 1
HB=$(read_hdr)
CKB=$(cksum_pix)
seqB=$(echo "$HB" | sed -n 's/.*seq=\([0-9]*\).*/\1/p')
PB=$(pulse_n)
# 模拟锁屏
printf '1\n' >"$V/.ziyan_display_locked"
chmod 666 "$V/.ziyan_display_locked"
sleep 8
HA=$(read_hdr)
CKA=$(cksum_pix)
seqA=$(echo "$HA" | sed -n 's/.*seq=\([0-9]*\).*/\1/p')
PA=$(pulse_n)
dLock=$((PA - PB))
echo "PB=$PB PA=$PA PULSE_LOCK_DELTA=$dLock"
echo "HB=$HB HA=$HA"
echo "CKB=$CKB CKA=$CKA"
G2_PULSE=FAIL
[ "$dLock" -ge 4 ] && G2_PULSE=PASS
G2_REFRESH=FAIL
[ -n "$seqA" ] && [ -n "$seqB" ] && [ "$seqA" != "$seqB" ] && G2_REFRESH=PASS
[ -n "$CKA" ] && [ -n "$CKB" ] && [ "$CKA" != "$CKB" ] && G2_REFRESH=PASS
echo "G2_PULSE=$G2_PULSE G2_REFRESH=$G2_REFRESH"
# 解锁
printf '0\n' >"$V/.ziyan_display_locked"
rm -f "$V/.ziyan_display_locked"
sleep 2

echo "=== G3 POST UNLOCK 12s ==="
SF2=$(lc 'serve_force')
P2=$(pulse_n)
sleep 12
SF3=$(lc 'serve_force')
P3=$(pulse_n)
d3=$((P3 - P2))
dsf3=$((SF3 - SF2))
echo "PULSE_DELTA=$d3 serve_force_delta=$dsf3"
G3=PASS
[ "$d3" -lt 6 ] && G3=FAIL
[ "$dsf3" -gt 5 ] && G3=FAIL
echo "G3_STEADY=$G3"

echo "=== G4 BID FLIP 10x ==="
RLB=$(lc 'relay_req|home_force_recap|front_bid_chg')
SFB=$(lc 'serve_force')
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
RLA=$(lc 'relay_req|home_force_recap|front_bid_chg')
SFA=$(lc 'serve_force')
ESTORM=$((RLA - RLB + SFA - SFB))
echo "ESTORM=$ESTORM"
G4=PASS
[ "$ESTORM" -gt 30 ] && G4=FAIL
echo "G4_HAND=$G4"
printf 'com.xztl.ios\n' >"$V/.ziyan_front_bid" 2>/dev/null

OVERALL=PASS
[ "$G1" != PASS ] && OVERALL=FAIL
[ "$G2_PULSE" != PASS ] && OVERALL=FAIL
[ "$G2_REFRESH" != PASS ] && OVERALL=FAIL
[ "$G3" != PASS ] && OVERALL=FAIL
[ "$G4" != PASS ] && OVERALL=FAIL
echo "=== SUMMARY ==="
echo "G1=$G1 G2_PULSE=$G2_PULSE G2_REFRESH=$G2_REFRESH G3=$G3 G4=$G4"
echo "OVERALL=$OVERALL"
