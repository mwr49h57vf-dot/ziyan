#!/usr/bin/env bash
# P1：找色契约门禁（不依赖桌面图标/游戏）
# T1 hit / T2 pixel_miss / T3 front_mismatch / T4 contract_meta
# 用法: bash tools/zy_find_contract_gate.sh [all|53|112|166]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/FIND_CONTRACT_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

run_one() {
  local tag="$1" ip="$2" scheme="$3"
  echo "[contract] .$tag"
  ssh_r "$ip" "TAG=$tag SCHEME=$scheme bash -s" <<'EOS' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var
else
  V=/usr/lib/ziyan/var
fi
MEDIA=/private/var/mobile/Media/ZiYan
mkdir -p "$MEDIA" "$V"
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
echo "META VER=$VER host=.$TAG"
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; sleep 1
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon" "$V/.ziyan_last_find" \
  "$V/.ziyan_find_contract" "$V/.ziyan_embed_off" "$MEDIA/_contract_out.txt"
echo 1 >"$V/.ziyan_embed_on"
# 202：禁 kickstart -k
launchctl kickstart system/com.ziyan.framecap 2>/dev/null || \
  launchctl kickstart com.ziyan.framecap 2>/dev/null || true
sleep 1.2
for i in 1 2 3 4 5; do
  echo 1 >"$V/.ziyan_go_home"; sleep 0.7; rm -f "$V/.ziyan_go_home"
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "$F" | grep -qi springboard && break
done
# 暖帧：等到 framecap log ok 且 resident/shm 有字节
for t in $(seq 1 25); do
  echo 1 >"$V/.ziyan_force_recap"
  echo "nonce=fc_warm_$t" >"$V/.ziyan_frame_req"
  sleep 1
  RES=""; [ -f "$V/.ziyan_resident_bytes" ] && RES=$(tr -d '\r\n' <"$V/.ziyan_resident_bytes" | head -c 20)
  LOG=""; [ -f "$V/.ziyan_framecap_log" ] && LOG=$(tail -1 "$V/.ziyan_framecap_log")
  echo "WARM t=$t RES=$RES LOG=$LOG"
  echo "$RES" | grep -qE '^[0-9]{4,}' && echo "$LOG" | grep -qE 'ok=1|via=' && break
done
sleep 0.5

# 路径写死进脚本，避免 getenv/setfenv 差异
cat >"$MEDIA/_find_contract_run.lua" <<LUA
local OUTF = "$MEDIA/_contract_out.txt"
local VAR = "$V"
local function w(s)
  local f = io.open(OUTF, "a"); if f then f:write(tostring(s) .. "\\n"); f:close() end
end
local function sleep_ms(ms)
  if type(mSleep) == "function" then mSleep(ms)
  elseif type(ziyan_embed_msleep) == "function" then ziyan_embed_msleep(ms) end
end
local function read_last()
  local lf = io.open(VAR .. "/.ziyan_last_find", "r")
  local last = lf and (lf:read("*l") or "") or ""
  if lf then lf:close() end
  return last
end
pcall(os.remove, OUTF)
w("start")

-- 暖：多取几次色，等帧就绪
local c = -1
for i = 1, 12 do
  if type(getColor) == "function" then c = tonumber(getColor(20, 20)) or -1 end
  if c >= 0 then break end
  local rf = io.open(VAR .. "/.ziyan_force_recap", "w"); if rf then rf:write("1\\n"); rf:close() end
  local rq = io.open(VAR .. "/.ziyan_frame_req", "w"); if rq then rq:write("nonce=t1_" .. i .. "\\n"); rq:close() end
  sleep_ms(400)
end
w("T1_color=" .. tostring(c))
local hx, hy = -1, -1
if c >= 0 and type(findMultiColorInRegionFuzzy) == "function" then
  hx, hy = findMultiColorInRegionFuzzy(c, "", 90, 0, 0, 120, 120)
end
local last = read_last()
w(string.format("T1_xy=%s,%s", tostring(hx), tostring(hy)))
w("T1_last=" .. last)
if tonumber(hx) and hx >= 0 then w("T1=PASS") else w("T1=FAIL") end

-- T2：有帧后找不可能色（主色取反 + 极端偏点）→ pixel_miss
local missc = 0x010203
if c >= 0 then missc = (0xFFFFFF - c) % 0x1000000 end
if missc == c then missc = (c + 0x123456) % 0x1000000 end
local mx, my = -1, -1
if type(findMultiColorInRegionFuzzy) == "function" then
  mx, my = findMultiColorInRegionFuzzy(missc, "3|5|0x010203,7|9|0xfefefe", 100, 0, 0, 30, 30)
end
last = read_last()
w(string.format("T2_xy=%s,%s missc=%s", tostring(mx), tostring(my), tostring(missc)))
w("T2_last=" .. last)
if (not tonumber(mx) or mx < 0) and string.find(last, "pixel_miss") then
  w("T2=PASS")
elseif (not tonumber(mx) or mx < 0) and string.find(last, "class=") then
  w("T2=PASS")
else
  w("T2=FAIL")
end

-- T3：真实元数据错位。旧版伪造 shm_front_bid，framecap 会在同一轮内把它修回，
-- Lua 因而读到上一条 pixel_miss。这里保留已捕获的 Home 帧，只短暂把 front_bid
-- 改成假 App；生产路径实际比较 front/shm，调用后立刻恢复，不依赖测试后门。
local front_bak = nil
do
  local f = io.open(VAR .. "/.ziyan_front_bid", "r")
  if f then front_bak = f:read("*a"); f:close() end
end
local wf = io.open(VAR .. "/.ziyan_front_bid", "w")
if wf then wf:write("com.ziyan.contract.fakeapp\\n"); wf:close() end
local fx, fy = -1, -1
if type(findMultiColorInRegionFuzzy) == "function" then
  fx, fy = findMultiColorInRegionFuzzy(0xFFFFFF, "", 90, 0, 0, 40, 40)
end
last = read_last()
w(string.format("T3_xy=%s,%s", tostring(fx), tostring(fy)))
w("T3_last=" .. last)
if front_bak then
  local rf = io.open(VAR .. "/.ziyan_front_bid", "w"); if rf then rf:write(front_bak); rf:close() end
else
  pcall(os.remove, VAR .. "/.ziyan_front_bid")
end
local rf2 = io.open(VAR .. "/.ziyan_force_recap", "w"); if rf2 then rf2:write("1\\n"); rf2:close() end
if string.find(last, "front_mismatch") or string.find(last, "frame_front_mismatch")
    or string.find(last, "stale") then
  w("T3=PASS")
else
  w("T3=FAIL")
end

local cf = io.open(VAR .. "/.ziyan_find_contract", "r")
local cbody = cf and (cf:read("*l") or "") or ""
if cf then cf:close() end
w("T4_contract=" .. cbody)
if string.find(cbody, "roi=") and string.find(cbody, "class=") then w("T4=PASS") else w("T4=FAIL") end
w("done")
LUA
chmod 666 "$MEDIA/_find_contract_run.lua"

printf 'path=%s/_find_contract_run.lua\nstop=0\n' "$MEDIA" >"$V/.ziyan_run_intent"
printf '%s/_find_contract_run.lua\n' "$MEDIA" >"$V/.ziyan_embed_script"
echo "nonce=fc_${TAG}_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_go"

for i in $(seq 1 80); do
  [ -f "$MEDIA/_contract_out.txt" ] && grep -q '^done$' "$MEDIA/_contract_out.txt" 2>/dev/null && break
  sleep 0.5
done
sleep 1
echo "---- OUT ----"
cat "$MEDIA/_contract_out.txt" 2>/dev/null || echo "NO_OUT"
echo "LAST_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find" 2>/dev/null)"
echo "CONTRACT=$(tr '\n' ' ' <"$V/.ziyan_find_contract" 2>/dev/null)"
echo "LIFE=$(tr '\n' ' ' <"$V/.ziyan_frame_lifecycle" 2>/dev/null)"

PASSN=0; FAILN=0
for t in T1 T2 T3 T4; do
  if grep -q "^${t}=PASS" "$MEDIA/_contract_out.txt" 2>/dev/null; then
    echo "PASS $t"; PASSN=$((PASSN+1))
  else
    echo "FAIL $t"; FAILN=$((FAILN+1))
  fi
done
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; sleep 1
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon"
if [ "$FAILN" = 0 ] && [ "$PASSN" = 4 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL PASS=$PASSN FAIL=$FAILN"; fi
EOS
}

case "$WANT" in
  all) run_one 53 192.168.31.53 rootless; run_one 112 192.168.31.112 rootful; run_one 166 192.168.31.166 rootful ;;
  53) run_one 53 192.168.31.53 rootless ;;
  112) run_one 112 192.168.31.112 rootful ;;
  166) run_one 166 192.168.31.166 rootful ;;
  *) echo "usage: $0 [all|53|112|166]"; exit 2 ;;
esac

P=0; F=0
for f in "$OUT"/gate_*.txt; do
  [ -f "$f" ] || continue
  echo "==== $(basename "$f") ===="; tail -40 "$f"
  if grep -q 'VERDICT=PASS' "$f"; then P=$((P+1)); else F=$((F+1)); fi
done
{
  echo "# FIND contract gate"
  echo "stamp=$STAMP"
  echo "PASS_HOSTS=$P FAIL_HOSTS=$F"
  if [ "$F" = 0 ] && [ "$P" -gt 0 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
