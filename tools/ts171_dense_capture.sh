#!/bin/bash
# .171 本机密采：min 前后只 wget+md5，不做判色（最快）。Mac 再离线分析。
set +e
OUT=/var/mobile/Media/TouchSprite/tmp/zy_dense
rm -rf "$OUT"
mkdir -p "$OUT"
URL='http://127.0.0.1:50005/snapshot1?ext=jpg&orient=1&compress=0.4&scale=1'
ROUNDS=${1:-3}
# 等登录：先密采 3s 给 Mac 判；这里用文件大小变化凑合，真正判色在 Mac
echo "TS_STATUS=$(wget -q -O - -T 2 http://127.0.0.1:50005/status)"
for r in $(seq 1 "$ROUNDS"); do
  echo "==== ROUND $r ===="
  RD=$OUT/r$r
  mkdir -p "$RD"
  # pre: 1.5s
  T0=$(date +%s)
  i=0
  while [ $(( $(date +%s) - T0 )) -lt 2 ]; do
    i=$((i+1))
    wget -q -O "$RD/pre_${i}.jpg" -T 2 "$URL"
  done
  echo "pre_n=$i"
  # min
  date +%s >"$RD/t0_epoch.txt"
  /usr/bin/ziyan_minall >"$RD/minall.txt" 2>&1
  date +%s >"$RD/t1_epoch.txt"
  # post: 12s dense
  T1=$(date +%s)
  j=0
  while [ $(( $(date +%s) - T1 )) -lt 12 ]; do
    j=$((j+1))
    # 文件名带序号；墙钟用目录 mtime
    wget -q -O "$RD/post_$(printf '%04d' $j).jpg" -T 2 "$URL"
  done
  echo "post_n=$j"
  ls -la "$RD" | head -5
  echo "ROUND $r done pre=$i post=$j"
done
echo DONE >"$OUT/DONE"
ls -la "$OUT"
echo OUT=$OUT
