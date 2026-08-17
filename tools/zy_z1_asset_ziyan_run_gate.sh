#!/usr/bin/env bash
# Z1-ASSET：独立 ziyan_run findImage 回执自证
# keep+文件 shm 裁块（禁 HTTP /snapshot）。不启 Desktop lua，不碰 .53，不杀 SB。
# 用法: bash tools/zy_z1_asset_ziyan_run_gate.sh 112 101 166
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/Z1_ASSET_ZIYAN_RUN_${STAMP}"
mkdir -p "$OUT"
CROP_FX="${ZY_ASSET_FX:-0.40}"
CROP_FY="${ZY_ASSET_FY:-0.40}"
CROP_W="${ZY_ASSET_W:-48}"
CROP_H="${ZY_ASSET_H:-48}"
TOL="${ZY_ASSET_TOL:-12}"

ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_from() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "root@$1:$2" "$3"; }

push_text() {
  ssh_r "$2" "mkdir -p \"\$(dirname '$3')\" && cat > '$3'" <"$1"
}
push_bin() {
  local n
  for n in 1 2 3; do
    if base64 <"$1" | ssh_r "$2" \
        "mkdir -p \"\$(dirname '$3')\" && base64 -d > '$3'" 2>/dev/null; then
      local got want
      got=$(ssh_r "$2" "wc -c <'$3' 2>/dev/null" 2>/dev/null | tr -d ' \r\n')
      want=$(wc -c <"$1" | tr -d ' ')
      [ "${got:-0}" = "$want" ] && return 0
    fi
    sleep 1
  done
  return 1
}

patch_wait() {
  local H="$1" IP="192.168.31.$H"
  local REM="/usr/lib/ziyan/lib/lua/ziyan_engine/cv.lua"
  local LOC="$OUT/cv_${H}.lua"
  scp_from "$IP" "$REM" "$LOC" || return 1
  cp -f "$LOC" "$OUT/cv_${H}.lua.bak"
  python3 - "$LOC" "$ROOT/tools/_wait_rep_wall_snippet.lua" <<'PY'
import re, sys
p, snip = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
new = open(snip, encoding="utf-8").read().rstrip() + "\n"
pat = r"local function wait_rep_wall\(want_nonce, timeout_s\).*?return false, nil\nend\n"
s2, n = re.subn(pat, new + "\n", s, count=1, flags=re.S)
if n != 1:
    raise SystemExit("wait_rep_wall replace failed n=%d" % n)
open(p, "w", encoding="utf-8").write(s2)
print("PATCH_OK")
PY
  ssh_r "$IP" "test -f '${REM}.pre_waitfix' || cp -f '$REM' '${REM}.pre_waitfix'"
  if ! push_bin "$LOC" "$IP" "$REM"; then
    echo "PATCH_PUSH_FAIL"
    return 1
  fi
  ssh_r "$IP" "/usr/lib/ziyan/bin/lua5.3 -e 'local ok,err=pcall(dofile,\"$REM\"); print(ok and \"CV_PARSE_OK\" or tostring(err))'; grep -c '/bin/sleep' '$REM'"
}

run_one() {
  local H="$1"
  local IP="192.168.31.$H"
  local VAR=/usr/lib/ziyan/var
  local BIN=/usr/lib/ziyan/bin
  local LUA=/usr/lib/ziyan/lib/lua
  local ZYCV=/private/var/mobile/Media/ZiYan/ZYCV
  echo "==== ziyan_run findImage .$H ===="

  ssh_r "$IP" "VAR='$VAR' ZYCV='$ZYCV' bash -s" >"$OUT/keep_${H}.txt" 2>&1 <<'EOS' || true
set +e
wait_rep() {
  local n="$1" lim="${2:-30}" i=0
  while [ "$i" -lt "$lim" ]; do
    if [ -f "$VAR/.ziyan_color_rep" ] && grep -q "$n" "$VAR/.ziyan_color_rep" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1)); sleep 0.1
  done
  return 1
}
mkdir -p "$ZYCV" && chmod 777 "$ZYCV"
n="gpre_$$"
rm -f "$VAR/.ziyan_color_rep"
printf 'getColor\n706\n449\n%s\n' "$n" >"$VAR/.ziyan_color_req.tmp"
mv "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
wait_rep "$n" 30 || true
echo GOLD=$(sed -n 3p "$VAR/.ziyan_color_rep" 2>/dev/null)
echo FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid")
n="keepon_$$"
rm -f "$VAR/.ziyan_color_rep"
printf 'keepScreen\n1\n%s\n' "$n" >"$VAR/.ziyan_color_req.tmp"
mv "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
if wait_rep "$n" 20; then echo KEEP_ACK=1; else echo KEEP_ACK=0; fi
echo PIN=$(test -f "$VAR/.ziyan_resident_pin" && echo 1 || echo 0)
cp -f "$VAR/.ziyan_frame_shm" "$ZYCV/_asset_shm.bin" 2>/dev/null
echo SHM_COPY=$(wc -c <"$ZYCV/_asset_shm.bin" 2>/dev/null | tr -d ' ')
EOS
  cat "$OUT/keep_${H}.txt"
  if ! grep -q 'KEEP_ACK=1' "$OUT/keep_${H}.txt"; then
    echo "VERDICT_${H}=FAIL reason=keep_ack_missing"
    return 1
  fi
  local GOLD
  GOLD=$(sed -n 's/^GOLD=//p' "$OUT/keep_${H}.txt" | tr -d '\r')
  if [ "$GOLD" != "12688231" ]; then
    echo "VERDICT_${H}=FAIL reason=gold_mismatch gold=$GOLD"
    return 1
  fi
  local COPY
  COPY=$(sed -n 's/^SHM_COPY=//p' "$OUT/keep_${H}.txt" | tr -d '\r')
  if [ "${COPY:-0}" -lt 1000 ] 2>/dev/null; then
    echo "VERDICT_${H}=FAIL reason=shm_copy_empty"
    return 1
  fi
  if ! scp_from "$IP" "$ZYCV/_asset_shm.bin" "$OUT/shm_${H}.bin"; then
    echo "VERDICT_${H}=FAIL reason=shm_scp_failed"
    return 1
  fi
  python3 - "$OUT/shm_${H}.bin" "$OUT/full_${H}.png" <<'PY'
import struct, sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
if len(data) < 64 or data[0:4] != b"ZYFR":
    raise SystemExit("bad shm")
w, h, bpr = struct.unpack_from("<III", data, 8)
fmt = data[48]
rows = []
swap = (fmt == 0)
for y in range(h):
    row = data[64 + y * bpr: 64 + y * bpr + w * 4]
    rgb = bytearray(w * 3)
    for x in range(w):
        a, b, c = row[x*4], row[x*4+1], row[x*4+2]
        if swap:
            rgb[x*3], rgb[x*3+1], rgb[x*3+2] = c, b, a
        else:
            rgb[x*3], rgb[x*3+1], rgb[x*3+2] = a, b, c
    rows.append(bytes(rgb))
Image.frombytes("RGB", (w, h), b"".join(rows)).save(dst)
print("SHM_PNG %dx%d fmt=%d" % (w, h, fmt))
PY

  local CROPINFO
  CROPINFO=$(python3 - "$OUT/full_${H}.png" "$OUT/crop_${H}.png" \
      "$CROP_FX" "$CROP_FY" "$CROP_W" "$CROP_H" <<'PY'
import sys
from PIL import Image
src, dst, fx, fy, cw, ch = sys.argv[1], sys.argv[2], float(sys.argv[3]), \
    float(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
im = Image.open(src).convert("RGB")
W, H = im.size
x = int(W * fx)
y = int(H * fy)
x = max(0, min(x, W - cw))
y = max(0, min(y, H - ch))
im.crop((x, y, x + cw, y + ch)).save(dst)
print("IMG_WH=%d,%d CROP_XY=%d,%d" % (W, H, x, y))
PY
)
  echo "$CROPINFO"
  local CX CY
  CX=$(echo "$CROPINFO" | sed -n 's/.*CROP_XY=\([0-9]*\),.*/\1/p')
  CY=$(echo "$CROPINFO" | sed -n 's/.*CROP_XY=[0-9]*,\([0-9]*\).*/\1/p')
  if ! push_bin "$OUT/crop_${H}.png" "$IP" "$ZYCV/_asset_crop.png"; then
    echo "VERDICT_${H}=FAIL reason=template_push_failed"
    return 1
  fi

  cat >"$OUT/find_${H}.lua" <<LUA
function main()
  init(1)
  keepScreen(true)
  local path = "/private/var/mobile/Media/ZiYan/ZYCV/_asset_crop.png"
  local t0 = os.time()
  local ix, iy = -1, -1
  if type(findImage) == "function" then
    ix, iy = findImage(path, 90)
  end
  local f = io.open("/private/var/mobile/Media/ZiYan/ZYCV/_asset_find_rep.txt", "w")
  if f then
    f:write(string.format("img=%s,%s\nexpect=${CX:-0},${CY:-0}\nwall=%s\nvia=ziyan_run\n",
      tostring(ix), tostring(iy), tostring((os.time() or 0) - t0)))
    f:close()
  end
  keepScreen(false)
end
LUA
  push_text "$OUT/find_${H}.lua" "$IP" "$ZYCV/_asset_find.lua"
  ssh_r "$IP" "rm -f '$ZYCV/_asset_find_rep.txt' '$VAR/.ziyan_color_rep'"
  local t0 t1
  t0=$(date +%s)
  ssh_r "$IP" "$BIN/lua5.3 $LUA/ziyan_run.lua $ZYCV/_asset_find.lua" \
    >"$OUT/runlua_${H}.txt" 2>&1 || true
  t1=$(date +%s)
  echo "LUA_WALL=$((t1 - t0))" | tee -a "$OUT/runlua_${H}.txt"
  ssh_r "$IP" "cat '$ZYCV/_asset_find_rep.txt' 2>/dev/null; echo --- color_rep ---; cat '$VAR/.ziyan_color_rep' 2>/dev/null; echo --- FC ---; ps -A -o args= | grep -F 'ziyan_framecap serve' | grep -vc grep" \
    >"$OUT/rep_${H}.txt" 2>&1 || true
  cat "$OUT/rep_${H}.txt"

  ssh_r "$IP" "VAR='$VAR' bash -s" >/dev/null 2>&1 <<'EOS' || true
n="keepoff_$$"
rm -f "$VAR/.ziyan_color_rep"
printf 'keepScreen\n0\n%s\n' "$n" >"$VAR/.ziyan_color_req.tmp"
mv "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
sleep 0.3
EOS

  local IMGLINE GX GY
  IMGLINE=$(grep -m1 '^img=' "$OUT/rep_${H}.txt" 2>/dev/null | tr -d '\r')
  GX=""; GY=""
  if [ -n "$IMGLINE" ]; then
    GX=${IMGLINE#img=}; GX=${GX%%,*}
    GY=${IMGLINE##*,}
  fi
  if [ -z "${GX:-}" ] || [ "${GX:-}" = "-1" ]; then
    local JLINE
    JLINE=$(grep -m1 '"x":' "$OUT/rep_${H}.txt" 2>/dev/null | tr -d '\r')
    if [ -n "$JLINE" ]; then
      GX=$(printf '%s\n' "$JLINE" | sed -n 's/.*"x":\([-0-9][0-9]*\).*/\1/p' | head -1)
      GY=$(printf '%s\n' "$JLINE" | sed -n 's/.*"y":\([-0-9][0-9]*\).*/\1/p' | head -1)
      echo "LUA_MISS_USE_DAEMON_JSON hit=${GX:-?},${GY:-?}"
    fi
  fi
  local OK=1
  if [ -z "${GX:-}" ] || [ "${GX:-}" = "-1" ]; then
    echo "FAIL .$H ziyan_run_findImage_miss img=${GX:-?},${GY:-?} expect=${CX},${CY}"
    OK=0
  else
    local DX=$(( GX - CX )); [ "$DX" -lt 0 ] && DX=$(( 0 - DX ))
    local DY=$(( GY - CY )); [ "$DY" -lt 0 ] && DY=$(( 0 - DY ))
    if [ "$DX" -gt "$TOL" ] || [ "$DY" -gt "$TOL" ]; then
      echo "FAIL .$H ziyan_run_wrong_xy got=$GX,$GY expect=$CX,$CY d=$DX,$DY"
      OK=0
    else
      echo "OK .$H ziyan_run hit=$GX,$GY expect=$CX,$CY d=$DX,$DY"
    fi
  fi
  if [ "$OK" = 1 ]; then echo "VERDICT_${H}=PASS"; else echo "VERDICT_${H}=FAIL"; fi
  [ "$OK" = 1 ]
}

HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then HOSTS=(112 101 166); fi
for H in "${HOSTS[@]}"; do
  echo "==== patch wait_rep_wall .$H ===="
  patch_wait "$H" | tee "$OUT/patch_${H}.txt"
done
PASS_N=0; FAIL_N=0
for H in "${HOSTS[@]}"; do
  if run_one "$H" 2>&1 | tee "$OUT/run_${H}.txt"; then :; fi
  if grep -q "VERDICT_${H}=PASS" "$OUT/run_${H}.txt" 2>/dev/null; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done
{
  echo "# Z1-ASSET 独立 ziyan_run 找图回执"
  echo "stamp=$STAMP hosts=${HOSTS[*]}"
  echo "方法：热补 wait_rep_wall(/bin/sleep 0.05+JSON兜底) → keep+shm 裁块 → ziyan_run findImage"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  [ "$FAIL_N" -eq 0 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ]
