#!/bin/bash
# 窄 ROI find_ms 门禁：对标 .171 p50≤40ms；业务稳态 avg_wall_ms
set +e
TAG="${1:-dev}"
V="${2:-/usr/lib/ziyan/var}"
echo "TAG=$TAG VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)"
echo "FRONT=$(tr '\n' ' ' <"$V/.ziyan_front_bid" 2>/dev/null)"
echo "PULSE0=$(cat "$V/.ziyan_find_pulse" 2>/dev/null)"
# 等 12s 攒 color_perf
sleep 12
PERF=$(cat "$V/.ziyan_color_perf" 2>/dev/null)
PULSE1=$(cat "$V/.ziyan_find_pulse" 2>/dev/null)
echo "PERF=$PERF"
echo "PULSE1=$PULSE1"
avg=$(echo "$PERF" | sed -n 's/.*avg_wall_ms=\([0-9.][0-9.]*\).*/\1/p' | head -1)
last=$(echo "$PERF" | sed -n 's/.*last_cpu_ms=\([0-9.][0-9.]*\).*/\1/p' | head -1)
n0=$(echo "$PULSE0" | sed -n 's/.*n=\([0-9]*\).*/\1/p')
n1=$(echo "$PULSE1" | sed -n 's/.*n=\([0-9]*\).*/\1/p')
dn=$(( ${n1:-0} - ${n0:-0} ))
echo "avg_wall_ms=${avg:-na} last_ms=${last:-na} pulse_delta=$dn"
# 门禁：12s 内至少 8 次；avg∈(0,80]（对标触动窄 ROI ≤40，先放宽机差）
OK=1
[ "$dn" -ge 8 ] || OK=0
case "${avg:-}" in
  ""|0|0.0|0.00) OK=0 ;;
esac
# 用整数比较：avg*10 ≤ 800
avg10=$(echo "${avg:-999}" | tr -dc '0-9.' | cut -d. -f1)
avg10=${avg10:-999}
[ "$avg10" -le 80 ] 2>/dev/null || OK=0
[ "$avg10" -ge 1 ] 2>/dev/null || OK=0
if [ "$OK" = 1 ]; then
  echo "OVERALL=PASS"
else
  echo "OVERALL=FAIL"
fi
