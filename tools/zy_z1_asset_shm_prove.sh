#!/usr/bin/env bash
# .112 同源自证：keep 钉帧后从 .ziyan_frame_shm 裁块，再 color_req findImage。
# 不走 HTTP /snapshot（会 force_recap，和 keep/resident 错开）。
# 不装包、不杀 SB、不改 Desktop lua、不碰匹配算法。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then HOSTS=(112); fi
OUT="$ROOT/tmp_shots/Z1_ASSET_SHM_PROVE_${STAMP}"
mkdir -p "$OUT"
TOL="${ZY_ASSET_TOL:-12}"
CROP_FX="${ZY_ASSET_FX:-0.40}"
CROP_FY="${ZY_ASSET_FY:-0.40}"
CROP_W="${ZY_ASSET_W:-48}"
CROP_H="${ZY_ASSET_H:-48}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=15
          -o ServerAliveCountMax=4)
ssh_r() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"
}

crop_shm() {
  python3 - "$1" "$2" "$CROP_FX" "$CROP_FY" "$CROP_W" "$CROP_H" <<'PY'
import struct, sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
fx, fy = float(sys.argv[3]), float(sys.argv[4])
cw, ch = int(sys.argv[5]), int(sys.argv[6])
data = open(src, "rb").read()
if len(data) < 64 or data[0:4] != b"ZYFR":
    print("SHM_BAD magic=%r bytes=%d" % (data[0:4], len(data)))
    sys.exit(2)
ver, w, h, bpr, seq = struct.unpack_from("<IIIII", data, 4)
ts_ms, payload = struct.unpack_from("<QQ", data, 24)
commit = struct.unpack_from("<I", data, 44)[0]
pixfmt, orient, provider, status = struct.unpack_from("BBBB", data, 48)
flags = struct.unpack_from("<I", data, 56)[0]
ws = flags & 0xFF
if ws < 1:
    ws = 1
need = 64 + bpr * h
print("SHM_HDR ver=%d wh=%d,%d bpr=%d seq=%d commit=%d fmt=%d orient=%d prov=%d st=%d flags=%u ws=%d bytes=%d need=%d" % (
    ver, w, h, bpr, seq, commit, pixfmt, orient, provider, status, flags, ws, len(data), need))
if w < 8 or h < 8 or bpr < w * 4 or len(data) < need:
    print("SHM_GEOM_BAD")
    sys.exit(2)
rows = []
off = 64
# 0=BGRA 1=RGBA；模板走 PNG RGB，须与 EncodeShmPNG/找图同一通道语义
swap_rb = (pixfmt == 0)
for y in range(h):
    row = data[off + y * bpr: off + y * bpr + w * 4]
    rgb = bytearray(w * 3)
    for x in range(w):
        b0, b1, b2 = row[x * 4], row[x * 4 + 1], row[x * 4 + 2]
        if swap_rb:
            rgb[x * 3] = b2
            rgb[x * 3 + 1] = b1
            rgb[x * 3 + 2] = b0
        else:
            rgb[x * 3] = b0
            rgb[x * 3 + 1] = b1
            rgb[x * 3 + 2] = b2
    rows.append(bytes(rgb))
im = Image.frombytes("RGB", (w, h), b"".join(rows))
x = int(w * fx)
y = int(h * fy)
x = max(0, min(x, w - cw))
y = max(0, min(y, h - ch))
patch = im.crop((x, y, x + cw, y + ch))
patch.save(dst)
cols = patch.getcolors(4096)
print("IMG_WH=%d,%d CROP_XY=%d,%d CROP_WH=%d,%d UNIQ=%d SWAP_RB=%d" % (
    w, h, x, y, cw, ch, len(cols) if cols else 9999, 1 if swap_rb else 0))
im.save(src + ".png")
PY
}

run_one() {
  local H="$1"
  local IP="192.168.31.${H}"
  local V=/usr/lib/ziyan/var
  local ZYCV=/private/var/mobile/Media/ZiYan/ZYCV
  echo "==== shm-prove .$H ===="
  ssh_r "$IP" "H='$H' V='$V' ZYCV='$ZYCV' bash -s" >"$OUT/pre_${H}.txt" 2>&1 <<'EOS' || true
set +e
wait_rep() {
  local n="$1" lim="${2:-20}"
  local i=0
  while [ "$i" -lt "$lim" ]; do
    if [ -f "$V/.ziyan_color_rep" ] && grep -q "$n" "$V/.ziyan_color_rep" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}
echo "FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)"
echo "SHM_BID=$(tr -d '\r\n' <"$V/.ziyan_shm_front_bid" 2>/dev/null)"
echo "KEEP0=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)"
echo "FC_N=$(ps -axo args= | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc 0-9)"
echo "SHM0=$(wc -c <"$V/.ziyan_frame_shm" 2>/dev/null | tr -d ' ')"
echo "WORKSET0=$(tr '\n' ' ' <"$V/.ziyan_workset_bytes" 2>/dev/null)"
# 空闲回收后文件 shm 可能是 0 字节；keep 在无像素时回 ok=0。
# 先 getColor 催一帧（同时灌 resident/shm），再 keep，再立刻拷 shm。
n="gpre_${H}_$$"
rm -f "$V/.ziyan_color_rep"
printf 'getColor\n706\n449\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
if wait_rep "$n" 30; then
  echo "GET_ACK=1 COLOR=$(sed -n 3p "$V/.ziyan_color_rep" | tr -d '\r')"
else
  echo "GET_ACK=0"
fi
echo "SHM1=$(wc -c <"$V/.ziyan_frame_shm" 2>/dev/null | tr -d ' ')"
n="keepon_${H}_$$"
rm -f "$V/.ziyan_color_rep"
printf 'keepScreen\n1\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
if wait_rep "$n" 20; then
  echo "KEEP_ACK=1 KEEP_REP=$(tr '\n' '|' <"$V/.ziyan_color_rep")"
else
  echo "KEEP_ACK=0 KEEP_REP=$(tr '\n' '|' <"$V/.ziyan_color_rep")"
fi
echo "KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)"
echo "SHM2=$(wc -c <"$V/.ziyan_frame_shm" 2>/dev/null | tr -d ' ')"
mkdir -p "$ZYCV" && chmod 777 "$ZYCV"
cp -f "$V/.ziyan_frame_shm" "$ZYCV/_asset_shm.bin" 2>/dev/null
echo "SHM_COPY=$(wc -c <"$ZYCV/_asset_shm.bin" 2>/dev/null | tr -d ' ')"
EOS
  cat "$OUT/pre_${H}.txt"
  local COPY COLOR KEEP_OK
  COPY=$(sed -n 's/^SHM_COPY=//p' "$OUT/pre_${H}.txt" | tr -d '\r')
  COLOR=$(sed -n 's/^GET_ACK=1 COLOR=//p' "$OUT/pre_${H}.txt" | tr -d '\r')
  KEEP_OK=$(grep -c 'KEEP_ACK=1' "$OUT/pre_${H}.txt" || true)
  if [ "${COLOR:-}" != "12688231" ]; then
    echo "VERDICT_${H}=FAIL reason=gold_mismatch color=${COLOR:-?}"
    return 1
  fi
  if [ "${KEEP_OK:-0}" -lt 1 ]; then
    echo "VERDICT_${H}=FAIL reason=keep_ack_missing"
    return 1
  fi
  if grep -q 'ok|0|' "$OUT/pre_${H}.txt" && grep -q 'KEEP_REP=' "$OUT/pre_${H}.txt"; then
    if echo "$(sed -n 's/^KEEP_ACK=1 KEEP_REP=//p' "$OUT/pre_${H}.txt")" | grep -q '|0|'; then
      echo "VERDICT_${H}=FAIL reason=keep_ok_0"
      return 1
    fi
  fi
  if [ "${COPY:-0}" -lt 1000 ] 2>/dev/null; then
    echo "VERDICT_${H}=FAIL reason=shm_copy_empty"
    return 1
  fi
  if ! sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
      "root@$IP:$ZYCV/_asset_shm.bin" "$OUT/shm_${H}.bin"; then
    echo "VERDICT_${H}=FAIL reason=shm_scp_failed"
    return 1
  fi
  if ! crop_shm "$OUT/shm_${H}.bin" "$OUT/crop_${H}.png" | tee "$OUT/crop_${H}.txt"; then
    echo "VERDICT_${H}=FAIL reason=shm_parse_failed"
    return 1
  fi
  local CX CY UNIQ
  CX=$(sed -n 's/.*CROP_XY=\([0-9]*\),.*/\1/p' "$OUT/crop_${H}.txt")
  CY=$(sed -n 's/.*CROP_XY=[0-9]*,\([0-9]*\).*/\1/p' "$OUT/crop_${H}.txt")
  UNIQ=$(sed -n 's/.*UNIQ=\([0-9]*\).*/\1/p' "$OUT/crop_${H}.txt")
  echo "EXPECT=$CX,$CY UNIQ=$UNIQ"
  local WANT GOT
  WANT=$(wc -c <"$OUT/crop_${H}.png" | tr -d ' ')
  if ! base64 <"$OUT/crop_${H}.png" | ssh_r "$IP" \
      "base64 -d > '$ZYCV/_asset_crop.png' && wc -c <'$ZYCV/_asset_crop.png'"; then
    echo "VERDICT_${H}=FAIL reason=tpl_push_failed"
    return 1
  fi
  GOT=$(ssh_r "$IP" "wc -c <'$ZYCV/_asset_crop.png'" | tr -d ' \r')
  echo "TPL want=$WANT got=$GOT"
  if [ "$GOT" != "$WANT" ]; then
    echo "VERDICT_${H}=FAIL reason=tpl_size_mismatch"
    return 1
  fi
  ssh_r "$IP" "H='$H' V='$V' ZYCV='$ZYCV' CX='$CX' CY='$CY' bash -s" \
      >"$OUT/find_${H}.txt" 2>&1 <<'EOS' || true
set +e
now_ms() { raw="${EPOCHREALTIME-}"; raw="${raw/./}"; printf '%s\n' "${raw:0:13}"; }
n="imgshm_${H}_$$"
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
tail -n 2 "$V/.ziyan_vision_gate" 2>/dev/null
echo "--- VIA ---"
cat "$V/.ziyan_find_via" 2>/dev/null
n2="keepoff_${H}_$$"
rm -f "$V/.ziyan_color_rep"
printf 'keepScreen\n0\n%s\n' "$n2" >"$V/.ziyan_color_req.tmp"
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
koff=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f "$V/.ziyan_color_rep" ] && grep -q "$n2" "$V/.ziyan_color_rep" 2>/dev/null; then
    koff=1; break
  fi
  sleep 0.1
done
echo "KEEP_OFF_ACK=$koff KEEP_LEFT=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)"
n3="g_${H}_$$"
rm -f "$V/.ziyan_color_rep"
printf 'getColor\n706\n449\n%s\n' "$n3" >"$V/.ziyan_color_req.tmp"
t1=$(now_ms)
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
gok=0
gms=-1
while :; do
  if [ -f "$V/.ziyan_color_rep" ] && grep -q "$n3" "$V/.ziyan_color_rep" 2>/dev/null; then
    gok=1
  fi
  now=$(now_ms)
  gms=$((now - t1))
  [ "$gok" = 1 ] && break
  [ "$gms" -ge 3000 ] && break
  sleep 0.05
done
echo "GET ack=$gok ms=$gms color=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')"
rm -f "$ZYCV/_asset_shm.bin" "$ZYCV/_asset_crop.png"
EOS
  cat "$OUT/find_${H}.txt"
  local BODY GX GY
  BODY=$(awk '/^--- REP ---/{p=1;next} /^--- /{p=0} p' "$OUT/find_${H}.txt" | tr -d '\r')
  GX=$(printf '%s\n' "$BODY" | sed -n 's/.*"x":\([-0-9][0-9]*\).*/\1/p' | head -1)
  GY=$(printf '%s\n' "$BODY" | sed -n 's/.*"y":\([-0-9][0-9]*\).*/\1/p' | head -1)
  echo "HIT=${GX:-?},${GY:-?} EXPECT=$CX,$CY"
  if [ -z "${GX:-}" ] || [ "$GX" = "-1" ]; then
    echo "VERDICT_${H}=FAIL reason=findImage_miss"
    return 1
  fi
  local DX=$((GX - CX)); [ "$DX" -lt 0 ] && DX=$((0 - DX))
  local DY=$((GY - CY)); [ "$DY" -lt 0 ] && DY=$((0 - DY))
  if [ "$DX" -gt "$TOL" ] || [ "$DY" -gt "$TOL" ]; then
    if [ "${UNIQ:-0}" -le 1 ]; then
      echo "WARN .$H hit_off_uniform d=$DX,$DY"
    else
      echo "VERDICT_${H}=FAIL reason=wrong_xy got=$GX,$GY expect=$CX,$CY d=$DX,$DY"
      return 1
    fi
  fi
  echo "VERDICT_${H}=PASS hit=$GX,$GY expect=$CX,$CY d=$DX,$DY ms=$(sed -n 's/^ACK=.*MS=//p' "$OUT/find_${H}.txt" | head -1)"
  return 0
}

PASS_N=0
FAIL_N=0
for H in "${HOSTS[@]}"; do
  if run_one "$H"; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done
{
  echo "# Z1-ASSET shm 同源自证"
  echo "stamp=$STAMP hosts=${HOSTS[*]} tol=$TOL"
  echo "方法：keepScreen(true) → 拷 .ziyan_frame_shm → Mac 裁 48x48@0.40,0.40 → color_req findImage → keep off"
  echo "不走 HTTP /snapshot（force_recap 会和 keep/resident 错开）"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  if [ "$FAIL_N" -eq 0 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
} | tee "$OUT/REPORT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ]
