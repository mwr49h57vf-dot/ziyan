#!/bin/bash
# 在 .171 本机跑：100ms 级采样（避免 Mac SSH 漏窗）
# 不改 main.lua。用法：scp 到机后 bash /tmp/ts171_ondev_step.sh
set +e
OUT=/var/mobile/Media/TouchSprite/tmp/zy_step
rm -rf "$OUT"
mkdir -p "$OUT/snaps"
ROUNDS=${1:-3}
AFTER_MS=${2:-12000}
URL='http://127.0.0.1:50005/snapshot1?ext=jpg&orient=1&compress=0.45&scale=1'
TSV=$OUT/timeline.tsv
echo -e "round\tphase\tdt_ms\tcksum\tfind\tlogin\tw\th\tevent" >"$TSV"

# 纯 shell 判色：用 od 读 jpg 不可靠 → 用 TS 无，改用更粗：调 ziyan 无
# 机上有 perl? 用 python 若无则用 wget+外部
HAVE_PY=0
command -v python3 >/dev/null && HAVE_PY=1
command -v python >/dev/null && HAVE_PY=1
PY=python3
command -v python3 >/dev/null || PY=python

probe_one() {
  # args: jpg path → print find login w h cksum
  local f="$1"
  $PY - "$f" <<'PY'
import sys, hashlib
from struct import unpack
path=sys.argv[1]
data=open(path,'rb').read()
ck=hashlib.md5(data).hexdigest()[:10]
# minimal JPEG decode via PIL if present else fail
try:
  from PIL import Image
  from io import BytesIO
  im=Image.open(BytesIO(data)).convert('RGB')
except Exception:
  # fallback: try Cocoa via none — mark unknown
  print(f"0 0 0 0 {ck}")
  sys.exit(0)
w,h=im.size
px=im.load()
FIND=(1009,330,(0xbd,0x82,0x16))
LOGIN=(652,443,(0x90,0x64,0x3b))
TOL=40
def hit(xy,rgb,r=3):
  x,y=xy
  if x>=w or y>=h:
    x=int(xy[0]*w/1136); y=int(xy[1]*h/640)
  x=max(0,min(w-1,x)); y=max(0,min(h-1,y))
  for dy in range(-r,r+1):
    for dx in range(-r,r+1):
      xx,yy=x+dx,y+dy
      if 0<=xx<w and 0<=yy<h:
        c=px[xx,yy]
        if abs(c[0]-rgb[0])<=TOL and abs(c[1]-rgb[1])<=TOL and abs(c[2]-rgb[2])<=TOL:
          return 1
  return 0
print(hit(FIND[:2],FIND[2]), hit(LOGIN[:2],LOGIN[2]), w, h, ck)
PY
}

now_ms() {
  # iOS date may lack %N; use python
  $PY - <<'PY'
import time; print(int(time.time()*1000))
PY
}

wait_login() {
  local i=0
  while [ $i -lt 80 ]; do
    i=$((i+1))
    wget -q -O "$OUT/w.jpg" -T 2 "$URL" || { sleep 0.2; continue; }
    read F L W H CK <<EOF
$(probe_one "$OUT/w.jpg")
EOF
    echo "WAIT i=$i login=$L find=$F ck=$CK size=${W}x${H}"
    [ "$L" = 1 ] && cp "$OUT/w.jpg" "$OUT/snaps/wait_login_$i.jpg" && return 0
    sleep 0.25
  done
  return 1
}

for r in $(seq 1 "$ROUNDS"); do
  echo "==== ROUND $r ===="
  wait_login || { echo "FAIL no login r=$r"; continue; }
  # pre samples
  for i in 0 1 2 3; do
    wget -q -O "$OUT/p.jpg" -T 2 "$URL"
    read F L W H CK <<EOF
$(probe_one "$OUT/p.jpg")
EOF
    echo -e "$r\tpre\t$i\t$CK\t$F\t$L\t$W\t$H\tbaseline" >>"$TSV"
    cp "$OUT/p.jpg" "$OUT/snaps/r${r}_pre${i}_$CK.jpg"
  done
  T0=$(now_ms)
  echo -e "$r\tmin\t0\t-\t0\t0\t0\t0\tminall_begin" >>"$TSV"
  /usr/bin/ziyan_minall >/tmp/minall.out 2>&1
  echo -e "$r\tmin\t$(( $(now_ms) - T0 ))\t-\t0\t0\t0\t0\tminall_done $(tr '\n' ' ' </tmp/minall.out)" >>"$TSV"
  saw_find=0; saw_login_drop=0; saw_login_back=0
  t_find=-1; t_drop=-1; t_back=-1
  last_login=1
  n=0
  while [ $(( $(now_ms) - T0 )) -lt "$AFTER_MS" ]; do
    n=$((n+1))
    DT=$(( $(now_ms) - T0 ))
    wget -q -O "$OUT/c.jpg" -T 2 "$URL" || {
      echo -e "$r\tpost\t$DT\t?\t0\t0\t0\t0\tsnap_fail" >>"$TSV"
      continue
    }
    read F L W H CK <<EOF
$(probe_one "$OUT/c.jpg")
EOF
    EV="-"
    if [ "$last_login" = 1 ] && [ "$L" = 0 ]; then
      saw_login_drop=1; t_drop=$DT; EV="LOGIN_DROP"
      cp "$OUT/c.jpg" "$OUT/snaps/r${r}_DROP_${DT}ms_$CK.jpg"
    fi
    if [ "$F" = 1 ] && [ "$saw_find" = 0 ]; then
      saw_find=1; t_find=$DT; EV="FIND_FIRST"
      cp "$OUT/c.jpg" "$OUT/snaps/r${r}_FIND_${DT}ms_$CK.jpg"
    fi
    if [ "$saw_login_drop" = 1 ] && [ "$L" = 1 ] && [ "$saw_login_back" = 0 ]; then
      saw_login_back=1; t_back=$DT; EV="LOGIN_BACK"
      cp "$OUT/c.jpg" "$OUT/snaps/r${r}_LOGINBACK_${DT}ms_$CK.jpg"
    fi
    # 前 40 帧全留 + 事件帧
    if [ $n -le 40 ] || [ "$EV" != "-" ]; then
      cp "$OUT/c.jpg" "$OUT/snaps/r${r}_t${DT}_$CK.jpg"
    fi
    echo -e "$r\tpost\t$DT\t$CK\t$F\t$L\t$W\t$H\t$EV" >>"$TSV"
    echo "r$r +${DT}ms find=$F login=$L ck=$CK $EV"
    last_login=$L
    # 尽量快；wget+decode 是瓶颈
  done
  echo "ROUND_${r}_SUMMARY drop_ms=$t_drop find_ms=$t_find login_back_ms=$t_back find=$saw_find drop=$saw_login_drop back=$saw_login_back"
  echo "ROUND_${r}_SUMMARY drop_ms=$t_drop find_ms=$t_find login_back_ms=$t_back find=$saw_find drop=$saw_login_drop back=$saw_login_back" >>"$OUT/round_summary.txt"
done
echo DONE >"$OUT/DONE"
echo "OUT=$OUT"
