#!/usr/bin/env bash
# .101 vs .112 findImage color_req 回执对拍。不装包、不启 Desktop lua。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/Z1_ASSET_112_REPLY_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)
ssh_r() {
  local ip="$1"; shift
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@"
}

run_host() {
  local H="$1"
  local IP="192.168.31.${H}"
  local V=/usr/lib/ziyan/var
  local ZYCV=/private/var/mobile/Media/ZiYan/ZYCV
  echo "==== .$H ip=$IP ===="
  ssh_r "$IP" "echo FRONT=\$(tr -d '\r\n' <'$V/.ziyan_front_bid'); echo FC=\$(ps -axo args= | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc 0-9)"
  local PORT
  PORT=$(ssh_r "$IP" "cat '$V/.ziyan_snap_http_port' 2>/dev/null" | tr -dc '0-9')
  PORT="${PORT:-50005}"
  curl -s -m 20 -o "$OUT/full_${H}.png" -w "SNAP HTTP=%{http_code} bytes=%{size_download}\n" "http://$IP:$PORT/snapshot"
  python3 - "$OUT/full_${H}.png" "$OUT/crop_${H}.png" <<'PY'
from PIL import Image
import sys
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
cw, ch = 48, 48
x = int(W * 0.40)
y = int(H * 0.40)
x = max(0, min(x, W - cw))
y = max(0, min(y, H - ch))
patch = im.crop((x, y, x + cw, y + ch))
patch.save(sys.argv[2])
cols = patch.getcolors(4096)
print("IMG_WH=%d,%d CROP_XY=%d,%d UNIQ=%d" % (W, H, x, y, len(cols) if cols else 9999))
PY
  ssh_r "$IP" "mkdir -p '$ZYCV' && chmod 777 '$ZYCV'"
  base64 <"$OUT/crop_${H}.png" | ssh_r "$IP" "base64 -d > '$ZYCV/_asset_crop.png' && echo TPL=\$(wc -c <'$ZYCV/_asset_crop.png' | tr -d ' ')"
  ssh_r "$IP" "H='$H' V='$V' ZYCV='$ZYCV' bash -s" <<'EOS' | tee "$OUT/rep_${H}.txt"
set +e
now_ms() { raw="${EPOCHREALTIME-}"; raw="${raw/./}"; printf '%s\n' "${raw:0:13}"; }
n="img_${H}_$$"
rm -f "$V/.ziyan_color_rep"
printf 'findImage\n%s\n90\n0\n0\n1135\n639\n%s\n' "$ZYCV/_asset_crop.png" "$n" >"$V/.ziyan_color_req.tmp"
t0=$(now_ms)
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
ok=0
ms=-1
while :; do
  if [ -f "$V/.ziyan_color_rep" ] && grep -q "$n" "$V/.ziyan_color_rep" 2>/dev/null; then
    ok=1
  fi
  now=$(now_ms)
  ms=$((now - t0))
  [ "$ok" = 1 ] && break
  [ "$ms" -ge 20000 ] && break
  sleep 0.05
done
echo "ACK=$ok MS=$ms"
echo "--- REP ---"
cat "$V/.ziyan_color_rep" 2>/dev/null
echo "--- VISION ---"
tail -n 1 "$V/.ziyan_vision_gate" 2>/dev/null
echo "--- VIA ---"
cat "$V/.ziyan_find_via" 2>/dev/null
n2="g_${H}_$$"
rm -f "$V/.ziyan_color_rep"
printf 'getColor\n706\n449\n%s\n' "$n2" >"$V/.ziyan_color_req.tmp"
t1=$(now_ms)
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
gok=0
gms=-1
while :; do
  if [ -f "$V/.ziyan_color_rep" ] && grep -q "$n2" "$V/.ziyan_color_rep" 2>/dev/null; then
    gok=1
  fi
  now=$(now_ms)
  gms=$((now - t1))
  [ "$gok" = 1 ] && break
  [ "$gms" -ge 2000 ] && break
  sleep 0.05
done
echo "GET ack=$gok ms=$gms color=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')"
EOS
}

run_host 101
echo
run_host 112
echo "OUT=$OUT"
