#!/usr/bin/env bash
# 刀 E2：内存预算门禁（默认双机 .101+.53）
# 验收：
#   1) idle framecap RSS ≤ .171 TSDaemon 基线的 1.5x（或 ≤45MB）
#   2) 强制短 TTL：keep 后超时拆 KEEP，写 keep_ttl_fired
#   3) 停脚本后 KEEP=0，RSS 相对热跑不暴涨
# 用法: bash tools/zy_e2_mem_budget_gate.sh [101 53]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
if [ "$#" -eq 0 ]; then HOSTS=(101 53); else HOSTS=("$@"); fi
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/E2_MEM_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

# .171 基线（可覆盖）
TS_BASE_KB="${ZY_TS_RSS_KB:-32208}"
MAX_IDLE_KB=$(( TS_BASE_KB * 3 / 2 ))
[ "$MAX_IDLE_KB" -gt 46080 ] && MAX_IDLE_KB=46080

PASS_N=0
FAIL_N=0
for H in "${HOSTS[@]}"; do
  IP="192.168.31.$H"
  SCHEME=rootful
  [ "$H" = "53" ] && SCHEME=rootless
  echo "==== E2 .$H ===="
  ssh_r "$IP" "SCHEME=$SCHEME MAX_IDLE_KB=$MAX_IDLE_KB bash -s" <<'R' | tee "$OUT/gate_${H}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var; B=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var; B=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
mkdir -p "$MEDIA" "$V"
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
echo "VER=$VER"
rss_fc() {
  # 机上常无 awk：用 sed/cut
  line=$(ps -axo rss,args 2>/dev/null | grep '[z]iyan_framecap serve' | head -1)
  echo "$line" | sed 's/^ *//' | cut -d' ' -f1
}
# 清理
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
: >"$V/.ziyan_kill_scripts"; printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 1
rm -f "$V/.ziyan_embed_off" "$V/.ziyan_keep_daemon" "$V/.ziyan_session_keep" \
  "$V/.ziyan_active" "$V/.ziyan_keep_ttl_fired" "$V/.ziyan_embed_go" \
  "$V/.ziyan_lua_embedded" "$V/.ziyan_embed_alive" "$V/.ziyan_path_stats"
# 门禁用 8s TTL（双机通用，不依赖 @3x 猜 scale）
echo 8 >"$V/.ziyan_keep_ttl_sec"; chmod 666 "$V/.ziyan_keep_ttl_sec"
launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || true
sleep 1.5
IDLE=$(rss_fc); IDLE=${IDLE:-0}
echo "IDLE_RSS_KB=$IDLE MAX_IDLE_KB=$MAX_IDLE_KB"

# 探针：keep true → 睡 12s → find 若干 → 结束（停脚本拆 keep）
cat >"$MEDIA/_e2_mem_probe.lua" <<'LUA'
-- E2：显式 keep + 等 TTL；禁暗补锁
if type(keepScreen) == "function" then keepScreen(true) end
if type(mSleep) == "function" then mSleep(12000)
elseif type(ziyan_embed_msleep) == "function" then ziyan_embed_msleep(12000) end
for i = 1, 20 do
  if type(findMultiColorInRegionFuzzy) == "function" then
    findMultiColorInRegionFuzzy(0xFFFFFF, "", 90, 0, 0, 40, 40)
  end
  if type(mSleep) == "function" then mSleep(100)
  elseif type(ziyan_embed_msleep) == "function" then ziyan_embed_msleep(100) end
end
if type(keepScreen) == "function" then keepScreen(false) end
LUA
chmod 666 "$MEDIA/_e2_mem_probe.lua"
rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop" "$V/.ziyan_keep_ttl_fired"
printf 'path=%s/_e2_mem_probe.lua\nstop=0\n' "$MEDIA" >"$V/.ziyan_run_intent"
printf '%s/_e2_mem_probe.lua\n' "$MEDIA" >"$V/.ziyan_embed_script"
echo "nonce=e2_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_go"

# 等 keep 亮起
KEEP1=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$V/.ziyan_keep_daemon" ] && { KEEP1=1; break; }
  sleep 0.5
done
echo "KEEP_ON=$KEEP1 TTL=$(tr '\n' ' ' <"$V/.ziyan_keep_ttl" 2>/dev/null)"
HOT=$(rss_fc); HOT=${HOT:-0}
echo "HOT_RSS_KB=$HOT"

# 等 TTL 开火或脚本结束（最多 20s）
FIRED=0
for i in $(seq 1 40); do
  if [ -f "$V/.ziyan_keep_ttl_fired" ]; then FIRED=1; break; fi
  if [ ! -f "$V/.ziyan_lua_embedded" ] && [ ! -f "$V/.ziyan_embed_alive" ] && [ "$i" -gt 10 ]; then
    break
  fi
  sleep 0.5
done
echo "TTL_FIRED=$FIRED FIRED_BODY=$(cat "$V/.ziyan_keep_ttl_fired" 2>/dev/null | tr '\n' ' ')"

# 硬停
mkdir -p "$V"
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 3
KEEP2=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
AFTER=$(rss_fc); AFTER=${AFTER:-0}
echo "AFTER_KEEP=$KEEP2 AFTER_RSS_KB=$AFTER"

OK=1
echo "$VER" | grep -qE '194' || { echo "FAIL ver_not_194"; OK=0; }
[ "$IDLE" -gt 0 ] 2>/dev/null || { echo "FAIL idle_rss_zero"; OK=0; }
[ "$IDLE" -le "$MAX_IDLE_KB" ] 2>/dev/null || { echo "FAIL idle_rss=$IDLE>$MAX_IDLE_KB"; OK=0; }
[ "$KEEP1" = "1" ] || { echo "FAIL keep_never_on"; OK=0; }
[ "$FIRED" = "1" ] || { echo "FAIL ttl_not_fired"; OK=0; }
[ "$KEEP2" = "0" ] || { echo "FAIL sticky_keep_after_stop"; OK=0; }
# 停后不应相对 idle 暴涨 >2x（允许合帧后仍有槽）
LIM=$(( IDLE * 2 + 8192 ))
[ "$AFTER" -le "$LIM" ] 2>/dev/null || { echo "FAIL after_rss=$AFTER lim=$LIM"; OK=0; }
if [ "$OK" = 1 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
R
  if grep -q 'VERDICT=PASS' "$OUT/gate_${H}.txt" 2>/dev/null; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done

{
  echo "# E2 mem budget"
  echo "stamp=$STAMP hosts=${HOSTS[*]} ts_base_kb=$TS_BASE_KB max_idle_kb=$MAX_IDLE_KB"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  if [ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -gt 0 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -gt 0 ]
