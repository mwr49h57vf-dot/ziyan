#!/usr/bin/env bash
# 203：找图/OCR 固定资产门禁（非 Desktop 找色；不改 ios7/ios8p）
# 用法: bash tools/zy_vision_asset_gate.sh 101 [53]
# 流程：scp 模板 → 写短 Lua（仓库资产）→ embed/独立跑 → 检查 color_rep / ocr 旁路
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ASSETS="$ROOT/tests/vision_assets"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/RECTIFY_TS_203/VISION_ASSET_${STAMP}"
mkdir -p "$OUT"

ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$@"; }

run_one() {
  local H="$1"
  local IP="192.168.31.$H"
  local JB="" VAR BIN LUA
  if [ "$H" = "53" ]; then JB="/var/jb"; fi
  VAR="${JB}/usr/lib/ziyan/var"
  BIN="${JB}/usr/lib/ziyan/bin"
  LUA="${JB}/usr/lib/ziyan/lib/lua"
  echo "==== vision asset .$H ====" | tee -a "$OUT/summary.txt"
  scp_r "$ASSETS/tpl_color_patch.png" "root@$IP:/private/var/mobile/Media/ZiYan/ZYCV/tpl_color_patch.png"
  # 比例 ROI：用 getScreenSize，禁硬编码物理点
  cat >"$OUT/probe_${H}.lua" <<'LUA'
function main()
  init(1)
  local w,h = 1136,640
  if type(getScreenSize)=="function" then
    local a,b = getScreenSize()
    if tonumber(a) and tonumber(b) and a>1 and b>1 then w,h=a,b end
  end
  local path="/private/var/mobile/Media/ZiYan/ZYCV/tpl_color_patch.png"
  local x1,y1,x2,y2 = math.floor(w*0.05), math.floor(h*0.05), math.floor(w*0.95), math.floor(h*0.95)
  local ix,iy = -1,-1
  if type(findImageInRegionFuzzy)=="function" then
    ix,iy = findImageInRegionFuzzy(path, 70, x1,y1,x2,y2)
  elseif type(findImage)=="function" then
    ix,iy = findImage(path, 70)
  end
  toast(string.format("VISION_IMG %s,%s", tostring(ix), tostring(iy)), 2)
  local tx = ""
  if type(getText)=="function" then
    local r = getText(math.floor(w*0.2), math.floor(h*0.2), math.floor(w*0.8), math.floor(h*0.5))
    tx = tostring(r or "")
  end
  toast("VISION_OCR "..(#tx>0 and "hit" or "empty"), 2)
  local f=io.open((os.getenv("ZIYAN_VAR") or "/usr/lib/ziyan/var").."/.ziyan_vision_asset_rep","w")
  if not f then
    f=io.open("/var/jb/usr/lib/ziyan/var/.ziyan_vision_asset_rep","w")
  end
  if f then
    f:write(string.format("img=%s,%s\nocr_len=%d\n", tostring(ix), tostring(iy), #tx))
    f:close()
  end
  mSleep(1500)
end
LUA
  scp_r "$OUT/probe_${H}.lua" "root@$IP:/private/var/mobile/Media/ZiYan/ZYCV/_vision_asset_probe.lua"
  ssh_r "$IP" bash -s <<R
set +e
VAR='$VAR'; BIN='$BIN'; LUA='$LUA'
rm -f "\$VAR/.ziyan_vision_asset_rep" "\$VAR/.ziyan_light"
echo 1 >"\$VAR/.ziyan_embed_on"
# 跑 8s
if [ -n "${JB}" ]; then
  export DYLD_LIBRARY_PATH=${JB}/usr/lib/ziyan/lib
  timeout 12 \$BIN/lua5.3 \$LUA/ziyan_run.lua /private/var/mobile/Media/ZiYan/ZYCV/_vision_asset_probe.lua
else
  timeout 12 \$BIN/lua5.3 \$LUA/ziyan_run.lua /private/var/mobile/Media/ZiYan/ZYCV/_vision_asset_probe.lua
fi
echo '--- rep ---'
cat "\$VAR/.ziyan_vision_asset_rep" 2>/dev/null
echo '--- gate ---'
tail -n 3 "\$VAR/.ziyan_vision_gate" 2>/dev/null
echo '--- workset ---'
cat "\$VAR/.ziyan_workset_bytes" 2>/dev/null
echo '--- find_via ---'
cat "\$VAR/.ziyan_find_via" 2>/dev/null
echo '--- FC_N ---'
ps -A -o command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -vc grep || true
R
}

HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then HOSTS=(101 53); fi
for H in "${HOSTS[@]}"; do
  run_one "$H" | tee "$OUT/run_${H}.txt"
done
echo "OUT=$OUT"
