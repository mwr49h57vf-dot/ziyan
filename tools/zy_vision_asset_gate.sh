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
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/RECTIFY_TS_203/VISION_ASSET_${STAMP}"
mkdir -p "$OUT"

# 裁剪块相对整屏的位置与大小（比例，禁硬编码物理点）
CROP_FX="${ZY_ASSET_FX:-0.40}"
CROP_FY="${ZY_ASSET_FY:-0.40}"
CROP_W="${ZY_ASSET_W:-48}"
CROP_H="${ZY_ASSET_H:-48}"
# 命中坐标允许的偏差（逻辑点）
TOL="${ZY_ASSET_TOL:-12}"

ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_from() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "root@$1:$2" "$3"; }

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

  # ---- 阶段 1：取当前整屏 ----
  # 走守护自己的 50005/50015 /snapshot，而不是脚本里的 snapshot()：
  # 独立 lua5.3 进程没有原生 dumpScreen/snapshotScreen，screen.lua 的
  # snapshot() 兜底只能返回 false。HTTP 端点取的是同一份 shm 帧，且
  # 无需在被测机上跑脚本，不会污染本门禁真正要验的 findImage。
  # 端口由设备侧在 50005/50015 里挑第一个能 bind 的，不能按 rootful/rootless
  # 猜死（实测 .112/.166 都是 50005），以设备写的 .ziyan_snap_http_port 为准。
  local PORT
  PORT=$(ssh_r "$IP" "cat '$VAR/.ziyan_snap_http_port' 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  [ -z "$PORT" ] && PORT=50005
  local SNAP_HTTP=0
  local i
  for i in 1 2 3; do
    if curl -s -m 30 -o "$OUT/full_${H}.png" \
         -w '%{http_code}' "http://$IP:$PORT/snapshot" 2>/dev/null | grep -q '^200$'; then
      SNAP_HTTP=1
      break
    fi
    sleep 2
  done
  if [ "$SNAP_HTTP" -ne 1 ]; then
    echo "VERDICT_${H}=FAIL reason=snapshot_http_failed port=$PORT"
    return 1
  fi
  echo "SNAPSHOT_HTTP=ok port=$PORT bytes=$(wc -c <"$OUT/full_${H}.png" | tr -d ' ')"

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
x = int(W * fx)
y = int(H * fy)
x = max(0, min(x, W - cw))
y = max(0, min(y, H - ch))
patch = im.crop((x, y, x + cw, y + ch))
patch.save(dst)
colors = patch.getcolors(maxcolors=4096)
uniq = len(colors) if colors else 9999
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
  if type(findImageInRegionFuzzy) == "function" then
    ix, iy = findImageInRegionFuzzy(path, 90, 0, 0, w - 1, h - 1)
  elseif type(findImage) == "function" then
    ix, iy = findImage(path, 90)
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
  local tx = ""
  if type(getText) == "function" then
    local r = getText(math.floor(w * 0.1), math.floor(h * 0.1),
                      math.floor(w * 0.9), math.floor(h * 0.6))
    tx = tostring(r or "")
  end
  local g = io.open(zycv .. "/_asset_find_rep.txt", "a")
  if g then
    g:write(string.format("ocr_len=%d\n", #tx))
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
  ssh_r "$IP" "VAR='$VAR' BIN='$BIN' LUA='$LUA' JB='$JB' TOL='$TOL' bash -s" \
      <<'R' >"$OUT/stage3_${H}.txt" 2>&1
set +e
ZYCV=/private/var/mobile/Media/ZiYan/ZYCV
rm -f "$ZYCV/_asset_find_rep.txt"
[ -n "$JB" ] && export DYLD_LIBRARY_PATH="$JB/usr/lib/ziyan/lib"
timeout 30 "$BIN/lua5.3" "$LUA/ziyan_run.lua" "$ZYCV/_asset_find.lua" 2>&1 | tail -5
echo "--- find rep ---"
cat "$ZYCV/_asset_find_rep.txt" 2>/dev/null
echo "--- vision gate ---"
tail -n 2 "$VAR/.ziyan_vision_gate" 2>/dev/null
echo "--- workset ---"
cat "$VAR/.ziyan_workset_bytes" 2>/dev/null
echo "--- find_via ---"
cat "$VAR/.ziyan_find_via" 2>/dev/null
# 与 E4 门禁同法计数：只认真实 serve 进程行，禁把 grep 自身计进去
FC_N=$(ps -axo pid=,args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
echo "--- FC_N ---"
echo "${FC_N:-0}"
rm -f "$ZYCV/_asset_full.png" "$ZYCV/_asset_crop.png" \
  "$ZYCV/_asset_shot.lua" "$ZYCV/_asset_find.lua" \
  "$ZYCV/_asset_shot_rep.txt" "$ZYCV/_asset_find_rep.txt"
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
  OCRLEN=$(sed -n 's/^ocr_len=\([0-9]*\).*/\1/p' "$OUT/stage3_${H}.txt" | head -1)
  FCN=$(sed -n '/--- FC_N ---/{n;p;}' "$OUT/stage3_${H}.txt" | tr -dc '0-9')
  OK=1
  if [ -z "${GX:-}" ] || [ "${GX:-−1}" = "-1" ]; then
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
  echo "方法：真机截屏 → Mac 裁块 → 真机搜该块，命中坐标须回到裁剪位置（tol=$TOL）"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  [ "$FAIL_N" -eq 0 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ]
