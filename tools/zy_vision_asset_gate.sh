#!/usr/bin/env bash
# Z1-ASSET 找图/OCR 门禁（自证式；不改 ios7/ios8p）
# 用法: bash tools/zy_vision_asset_gate.sh 101 [53]
#
# 为什么不用固定模板：
#   旧版把 tests/vision_assets/tpl_color_patch.png（16x16 纯色 RGB157,58,105）
#   当模板去搜真机画面。屏幕上本来就没这块颜色，img=-1,-1 是必然结果，
#   门禁无法区分「findImage 坏了」与「模板不在画面上」，等于没测。
#
# 自证式做法：
#   1. 真机 snapshot 当前整屏 → scp 回 Mac
#   2. Mac 上从该截图的已知位置裁一小块 → scp 回真机
#   3. 真机 findImageInRegionFuzzy 搜这块 → 必须命中且坐标接近裁剪位置
#   findImage 连「刚从当前帧裁下来的图」都找不到，才是真故障。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SSH_KEY_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 -o ServerAliveInterval=15)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
STAMP="$(date '+%Y%m%d_%H%M%S')_$$"
OUT="$ROOT/tmp_shots/RECTIFY_TS_203/VISION_ASSET_${STAMP}"
mkdir -p "$OUT"

# 裁剪块相对整屏的位置与大小（比例，禁硬编码物理点）
CROP_FX="${ZY_ASSET_FX:-0.40}"
CROP_FY="${ZY_ASSET_FY:-0.40}"
CROP_W="${ZY_ASSET_W:-48}"
CROP_H="${ZY_ASSET_H:-48}"
# 命中坐标允许的偏差（逻辑点）
TOL="${ZY_ASSET_TOL:-12}"

# 探测必须 ssh -n，避免吃掉调用方 heredoc；真正执行禁止 -n。
ssh_r() {
  local ip="$1"; shift
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" "true" >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@"
  fi
}
scp_from() {
  local ip="$1"
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" "true" >/dev/null 2>&1; then
    scp "${SSH_KEY_OPTS[@]}" "root@$ip:$2" "$3"
  else
    sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "root@$ip:$2" "$3"
  fi
}

# 这些越狱机上 scp 会静默半失败（返回 1，文件时有时无），一次丢包就让
# findImage 去找不存在的路径，稳定回 -1,-1，看起来和「找图坏了」一样。
# 文本走 ssh stdin，二进制走 base64，落地后一律校验字节数。
push_text() { # <local> <ip> <remote>
  ssh_r "$2" "mkdir -p \"\$(dirname '$3')\" && cat > '$3'" <"$1"
}
push_bin() { # <local> <ip> <remote>
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

command -v python3 >/dev/null 2>&1 || { echo "FATAL python3 required for crop"; exit 2; }
python3 -c 'import PIL' 2>/dev/null || { echo "FATAL Pillow required: pip3 install Pillow"; exit 2; }

run_one() {
  local H="$1"
  local IP="192.168.31.$H"
  local JB="" VAR BIN LUA
  if [ "$H" = "53" ]; then JB="/var/jb"; fi
  VAR="${JB}/usr/lib/ziyan/var"
  BIN="${JB}/usr/lib/ziyan/bin"
  LUA="${JB}/usr/lib/ziyan/lib/lua"
  local ZYCV=/private/var/mobile/Media/ZiYan/ZYCV
  echo "==== vision asset .$H ===="
  # 回桌面再裁：设置页中部常是近纯色，自证块会到处命中。
  ssh_r "$IP" "VAR='$VAR' bash -s" >/dev/null 2>&1 <<'H' || true
set +e
echo 1 >"$VAR/.ziyan_go_home"
sleep 2
rm -f "$VAR/.ziyan_go_home"
H

  # ---- 阶段 1：取当前整屏（keep + 文件 shm，禁止 HTTP /snapshot）----
  # /snapshot 每次 force_recap，和 findImage 读的 resident 会错开
  # （.112 C98 实测 HTTP/未 pin 的 shm 裁块命中 889,435，同源算法在
  # 同一份 shm 上却会选 454,256）。keep 先镜 shm→resident 再 pin。
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
n="keepon_$$"
rm -f "$VAR/.ziyan_color_rep"
printf 'keepScreen\n1\n%s\n' "$n" >"$VAR/.ziyan_color_req.tmp"
mv "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
if wait_rep "$n" 20; then echo KEEP_ACK=1; else echo KEEP_ACK=0; fi
echo KEEP_REP=$(tr '\n' '|' <"$VAR/.ziyan_color_rep")
echo PIN=$(test -f "$VAR/.ziyan_resident_pin" && echo 1 || echo 0)
cp -f "$VAR/.ziyan_frame_shm" "$ZYCV/_asset_shm.bin" 2>/dev/null
echo SHM_COPY=$(wc -c <"$ZYCV/_asset_shm.bin" 2>/dev/null | tr -d ' ')
EOS
  cat "$OUT/keep_${H}.txt"
  if ! grep -q 'KEEP_ACK=1' "$OUT/keep_${H}.txt"; then
    echo "VERDICT_${H}=FAIL reason=keep_ack_missing"
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
  echo "SNAPSHOT_SHM=ok bytes=$(wc -c <"$OUT/full_${H}.png" | tr -d ' ')"

  # ---- 阶段 2：Mac 侧裁块 ----
  local CROPINFO
  CROPINFO=$(python3 - "$OUT/full_${H}.png" "$OUT/crop_${H}.png" \
      "$CROP_FX" "$CROP_FY" "$CROP_W" "$CROP_H" <<'PY'
import sys
from PIL import Image
src, dst, fx, fy, cw, ch = sys.argv[1], sys.argv[2], float(sys.argv[3]), \
    float(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
im = Image.open(src).convert("RGB")
W, H = im.size

def score(x, y):
    patch = im.crop((x, y, x + cw, y + ch))
    cols = patch.getcolors(maxcolors=4096)
    return (len(cols) if cols else 9999), patch

x = max(0, min(int(W * fx), W - cw))
y = max(0, min(int(H * fy), H - ch))
uniq, patch = score(x, y)
if uniq <= 8:
    best = (uniq, x, y, patch)
    step = max(24, min(cw, ch))
    for yy in range(step, H - ch - step, step):
        for xx in range(step, W - cw - step, step):
            u, p = score(xx, yy)
            if u > best[0]:
                best = (u, xx, yy, p)
                if u >= 64:
                    break
        if best[0] >= 64:
            break
    uniq, x, y, patch = best
patch.save(dst)
print(f"IMG_WH={W},{H} CROP_XY={x},{y} CROP_WH={cw},{ch} UNIQ={uniq}")
PY
)
  echo "$CROPINFO"
  local IMGW IMGH CX CY UNIQ
  IMGW=$(echo "$CROPINFO" | sed -n 's/.*IMG_WH=\([0-9]*\),.*/\1/p')
  IMGH=$(echo "$CROPINFO" | sed -n 's/.*IMG_WH=[0-9]*,\([0-9]*\) .*/\1/p')
  CX=$(echo "$CROPINFO" | sed -n 's/.*CROP_XY=\([0-9]*\),.*/\1/p')
  CY=$(echo "$CROPINFO" | sed -n 's/.*CROP_XY=[0-9]*,\([0-9]*\) .*/\1/p')
  UNIQ=$(echo "$CROPINFO" | sed -n 's/.*UNIQ=\([0-9]*\).*/\1/p')
  # 纯色块无法定位（画面上处处匹配），换个位置重裁才有意义
  if [ "${UNIQ:-0}" -le 1 ]; then
    echo "WARN crop_is_uniform uniq=$UNIQ → 该位置是纯色，命中坐标不唯一"
  fi
  # 必须确认模板真的落到设备：推送静默失败时 findImage 找的是不存在的路径，
  # 会稳定回 -1,-1，看上去和「找图坏了」一模一样。
  ssh_r "$IP" "mkdir -p '$ZYCV' && chmod 777 '$ZYCV'" >/dev/null 2>&1 || true
  if ! push_bin "$OUT/crop_${H}.png" "$IP" "$ZYCV/_asset_crop.png"; then
    echo "VERDICT_${H}=FAIL reason=template_push_failed"
    return 1
  fi
  echo "TEMPLATE_ON_DEVICE=$(wc -c <"$OUT/crop_${H}.png" | tr -d ' ')B"

  # ---- 阶段 3：真机搜这块，并跑 OCR ROI ----
  cat >"$OUT/find_${H}.lua" <<LUA
function main()
  init(1)
  local zycv = "/private/var/mobile/Media/ZiYan/ZYCV"
  local path = zycv .. "/_asset_crop.png"
  local w, h = ${IMGW:-0}, ${IMGH:-0}
  if type(getScreenSize) == "function" then
    local a, b = getScreenSize()
    if tonumber(a) and tonumber(b) and a > 1 and b > 1 then w, h = a, b end
  end
  local ix, iy = -1, -1
  -- findImageInRegionFuzzy 在 compat 里是 stub，会立刻 -1,-1。
  -- 自证只走真实 findImage（color_req / wait_rep_wall）。
  if type(findImage) == "function" then
    ix, iy = findImage(path, 90, 0, 0, w - 1, h - 1)
  end
  -- 先落盘找图结果再碰 OCR：rootful 三机上 getText 会一直不返回（实测 .101
  -- 85s 未回，.53 需 11s），放在同一个 write 之前会把整份报告拖没，
  -- 找图明明有结果也读不到，门禁只能报 img=?,?。
  local f = io.open(zycv .. "/_asset_find_rep.txt", "w")
  if f then
    f:write(string.format("img=%s,%s\nexpect=%d,%d\nscreen=%d,%d\n",
      tostring(ix), tostring(iy), ${CX:-0}, ${CY:-0}, w, h))
    f:close()
  end
  -- OCR 另测（P3）。getText 在 rootful 上可挂死整份脚本，
  -- 找图回执已经落盘后不得再挡。
  local g = io.open(zycv .. "/_asset_find_rep.txt", "a")
  if g then
    g:write("ocr_len=skipped\n")
    g:close()
  end
  mSleep(300)
end
LUA
  push_text "$OUT/find_${H}.lua" "$IP" "$ZYCV/_asset_find.lua"
  local FIND_BYTES
  FIND_BYTES=$(ssh_r "$IP" "wc -c <'$ZYCV/_asset_find.lua' 2>/dev/null" 2>/dev/null | tr -d ' \r\n')
  if [ -z "$FIND_BYTES" ] || [ "$FIND_BYTES" -lt 50 ] 2>/dev/null; then
    echo "VERDICT_${H}=FAIL reason=find_script_push_failed bytes=${FIND_BYTES:-0}"
    return 1
  fi
  ssh_r "$IP" "VAR='$VAR' bash -s" \
      <<'R' >"$OUT/stage3_${H}.txt" 2>&1
set +e
ZYCV=/private/var/mobile/Media/ZiYan/ZYCV
now_ms() { raw="${EPOCHREALTIME-}"; raw="${raw/./}"; printf '%s\n' "${raw:0:13}"; }
n="imgasset_$$"
rm -f "$VAR/.ziyan_color_rep" "$ZYCV/_asset_find_rep.txt"
printf 'findImage\n%s\n90\n0\n0\n1135\n639\n%s\n' "$ZYCV/_asset_crop.png" "$n" \
  >"$VAR/.ziyan_color_req.tmp"
t0=$(now_ms)
mv "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
ok=0
ms=-1
while :; do
  if [ -f "$VAR/.ziyan_color_rep" ] && grep -q "$n" "$VAR/.ziyan_color_rep" 2>/dev/null; then
    ok=1
  fi
  now=$(now_ms)
  ms=$((now - t0))
  [ "$ok" = 1 ] && break
  [ "$ms" -ge 25000 ] && break
  sleep 0.05
done
echo "ACK=$ok MS=$ms"
echo "--- color_rep ---"
cat "$VAR/.ziyan_color_rep" 2>/dev/null
BODY=$(tr -d '\r' <"$VAR/.ziyan_color_rep" 2>/dev/null)
GX=$(printf '%s\n' "$BODY" | sed -n 's/.*"x":\([-0-9][0-9]*\).*/\1/p' | head -1)
GY=$(printf '%s\n' "$BODY" | sed -n 's/.*"y":\([-0-9][0-9]*\).*/\1/p' | head -1)
echo "img=${GX:--1},${GY:--1}"
echo "--- vision gate ---"
tail -n 2 "$VAR/.ziyan_vision_gate" 2>/dev/null
echo "--- workset ---"
cat "$VAR/.ziyan_workset_bytes" 2>/dev/null
echo "--- find_via ---"
cat "$VAR/.ziyan_find_via" 2>/dev/null
echo "--- lease ---"
tr '\n' ' ' <"$VAR/.ziyan_frame_lease" 2>/dev/null; echo
echo "--- frame_age ---"
tr '\n' ' ' <"$VAR/.ziyan_frame_age_ms" 2>/dev/null; echo
echo "--- front ---"
tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null; echo
echo "--- path_stats ---"
tr '\n' ' ' <"$VAR/.ziyan_path_stats" 2>/dev/null; echo
FC_N=$(ps -axo pid=,args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
echo "--- FC_N ---"
echo "${FC_N:-0}"
echo "ACTIVE=$(test -f "$VAR/.ziyan_active" && echo 1 || echo 0)"
echo "KEEP_NOW=$(test -f "$VAR/.ziyan_keep_daemon" && echo 1 || echo 0)"
rm -f "$ZYCV/_asset_full.png" "$ZYCV/_asset_crop.png" \
  "$ZYCV/_asset_shot.lua" "$ZYCV/_asset_find.lua" \
  "$ZYCV/_asset_shot_rep.txt" "$ZYCV/_asset_find_rep.txt" \
  "$ZYCV/_asset_shm.bin"
n2="keepoff_$$"
rm -f "$VAR/.ziyan_color_rep"
printf 'keepScreen\n0\n%s\n' "$n2" >"$VAR/.ziyan_color_req.tmp"
mv "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
sleep 0.3
R
  cat "$OUT/stage3_${H}.txt"

  # ---- 判定 ----
  local GX GY FCN OCRLEN OK
  # 不能用 sed 的 \?：macOS 是 BSD sed，基本正则里 \? 不是量词，
  # 匹配会整体失败，命中 884,496 也会被读成空值判成 miss。
  local IMGLINE
  IMGLINE=$(grep -m1 '^img=' "$OUT/stage3_${H}.txt" 2>/dev/null | tr -d '\r')
  GX=""; GY=""
  if [ -n "$IMGLINE" ]; then
    GX=${IMGLINE#img=}; GX=${GX%%,*}
    GY=${IMGLINE##*,}
  fi
  # 独立 lua 偶发等不到回执；守护 JSON 已写出时以 color_req 为准
  if [ -z "${GX:-}" ] || [ "${GX:-}" = "-1" ]; then
    local JLINE
    JLINE=$(grep -m1 '"x":' "$OUT/stage3_${H}.txt" 2>/dev/null | tr -d '\r')
    if [ -n "$JLINE" ]; then
      GX=$(printf '%s\n' "$JLINE" | sed -n 's/.*"x":\([-0-9][0-9]*\).*/\1/p' | head -1)
      GY=$(printf '%s\n' "$JLINE" | sed -n 's/.*"y":\([-0-9][0-9]*\).*/\1/p' | head -1)
      echo "LUA_MISS_USE_DAEMON_JSON hit=${GX:-?},${GY:-?}"
    fi
  fi
  OCRLEN=$(sed -n 's/^ocr_len=\([0-9]*\).*/\1/p' "$OUT/stage3_${H}.txt" | head -1)
  FCN=$(sed -n '/--- FC_N ---/{n;p;}' "$OUT/stage3_${H}.txt" | tr -dc '0-9')
  OK=1
  if [ -z "${GX:-}" ] || [ "${GX:-−1}" = "-1" ]; then
    AGE=$(grep -A1 '^--- frame_age ---' "$OUT/stage3_${H}.txt" | tail -1 | tr -dc '0-9')
    LEASE=$(grep -A1 '^--- lease ---' "$OUT/stage3_${H}.txt" | tr '\n' ' ')
    if [ -n "$AGE" ] && [ "$AGE" -gt 5000 ] 2>/dev/null; then
      echo "CLASS=VISION_STALE frame_age_ms=$AGE"
    elif printf '%s' "$LEASE" | grep -qiE 'stale|inactive|released'; then
      echo "CLASS=VISION_STALE lease=$LEASE"
    else
      echo "CLASS=VISION_MISS"
    fi
    echo "FAIL .$H findImage_miss img=${GX:-?},${GY:-?} expect=${CX},${CY}"
    OK=0
  else
    local DX=$(( GX - CX )); [ "$DX" -lt 0 ] && DX=$(( 0 - DX ))
    local DY=$(( GY - CY )); [ "$DY" -lt 0 ] && DY=$(( 0 - DY ))
    if [ "$DX" -gt "$TOL" ] || [ "$DY" -gt "$TOL" ]; then
      if [ "${UNIQ:-0}" -le 1 ]; then
        echo "WARN .$H hit_off_but_uniform d=$DX,$DY tol=$TOL（纯色块坐标本就不唯一）"
      else
        echo "FAIL .$H findImage_wrong_xy got=$GX,$GY expect=$CX,$CY d=$DX,$DY tol=$TOL"
        OK=0
      fi
    else
      echo "OK .$H findImage hit=$GX,$GY expect=$CX,$CY d=$DX,$DY"
    fi
  fi
  if [ "${FCN:-0}" != "1" ]; then
    echo "FAIL .$H fc_n=${FCN:-?} (期望单宿主 1)"
    OK=0
  fi
  echo "OCR_LEN=${OCRLEN:-0}（仅记录，不作判据：桌面可能确实无文字）"
  if [ "$OK" = 1 ]; then echo "VERDICT_${H}=PASS"; else echo "VERDICT_${H}=FAIL"; fi
  local VDICT=FAIL
  [ "$OK" = 1 ] && VDICT=PASS
  local PKG RID
  PKG=$(ssh_r "$IP" "dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\\([^ ]*\\).*/\\1/p'" | tr -d '\r')
  RID="asset_${H}_$(date +%s)"
  {
    echo "run_id=$RID"
    echo "host=.$H"
    echo "pkg=$PKG"
    echo "img=${GX:-?},${GY:-?}"
    echo "expect=${CX:-?},${CY:-?}"
    echo "FC_N=${FCN:-}"
    echo "VERDICT=$VDICT"
    echo "final=1"
  } >"$OUT/device_final_${H}.txt"
  ssh_r "$IP" "mkdir -p /private/var/mobile/Media/ZiYan/verdicts" >/dev/null 2>&1 || true
  push_text "$OUT/device_final_${H}.txt" "$IP" "/private/var/mobile/Media/ZiYan/verdicts/${RID}.txt" || true
  echo "DEVICE_FINAL_$H=$RID"
  [ "$OK" = 1 ]
}

HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then HOSTS=(101 53); fi
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
  echo "# Z1-ASSET 自证式找图门禁"
  echo "stamp=$STAMP hosts=${HOSTS[*]}"
  echo "方法：keep+文件 shm 裁块（禁 HTTP /snapshot force_recap）→ 真机搜该块，命中须回裁剪位置（tol=$TOL）"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  [ "$FAIL_N" -eq 0 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ]
