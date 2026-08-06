#!/usr/bin/env bash
# 刀 E1：强制 embed 热路径门禁（默认双机 .101+.53）
# 验收：via_color_req_find=0；无独立 lua5.3；未显式 keep 则 KEEP=0
# 用法: bash tools/zy_e1_embed_hotpath_gate.sh [101 53]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SEC="${ZY_E1_SEC:-90}"
if [ "$#" -eq 0 ]; then HOSTS=(101 53); else HOSTS=("$@"); fi
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/E1_EMBED_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

PASS_N=0
FAIL_N=0
for H in "${HOSTS[@]}"; do
  IP="192.168.31.$H"
  echo "==== E1 .$H (${SEC}s window) ===="
  SCHEME=rootful
  if [ "$H" = "53" ]; then SCHEME=rootless; fi
  {
    echo "HOST=.$H SCHEME=$SCHEME"
    ssh_r "$IP" "SCHEME=$SCHEME SEC=$SEC bash -s" <<'R' | tee "$OUT/gate_${H}.txt"
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
# 停旧会话 + 清 keep/embed 粘滞
mkdir -p "$V"
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
: >"$V/.ziyan_kill_scripts"; printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 1
rm -f "$V/.ziyan_embed_off" "$V/.ziyan_light" "$V/.ziyan_keep_daemon" \
  "$V/.ziyan_session_keep" "$V/.ziyan_active" "$V/.ziyan_color_req" \
  "$V/.ziyan_path_stats" "$V/.ziyan_embed_go" "$V/.ziyan_lua_embedded" \
  "$V/.ziyan_embed_alive"
# framecap
if [ -f /var/jb/Library/LaunchDaemons/com.ziyan.framecap.plist ]; then
  launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || true
elif [ -f /Library/LaunchDaemons/com.ziyan.framecap.plist ]; then
  launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || true
fi
sleep 1.2
# 写探针脚本
cat >"$MEDIA/_e1_embed_probe.lua" <<'LUA'
-- E1 embed hotpath probe（禁 color_req；禁暗 keep）
local n = 80
for i = 1, n do
  if type(findMultiColorInRegionFuzzy) == "function" then
    findMultiColorInRegionFuzzy(0xFFFFFF, "", 90, 0, 0, 80, 80)
  end
  if type(mSleep) == "function" then
    mSleep(80)
  elseif type(ziyan_embed_msleep) == "function" then
    ziyan_embed_msleep(80)
  end
end
LUA
chmod 666 "$MEDIA/_e1_embed_probe.lua"
rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop"
printf 'path=%s/_e1_embed_probe.lua\nstop=0\n' "$MEDIA" >"$V/.ziyan_run_intent"
printf '%s/_e1_embed_probe.lua\n' "$MEDIA" >"$V/.ziyan_embed_script"
echo "nonce=e1_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_go"
# 等跑完 / 窗口
end=$(( $(date +%s) + SEC ))
REQ_HITS=0
while [ "$(date +%s)" -lt "$end" ]; do
  [ -f "$V/.ziyan_color_req" ] && REQ_HITS=$((REQ_HITS + 1))
  if [ ! -f "$V/.ziyan_lua_embedded" ] && [ ! -f "$V/.ziyan_embed_alive" ] \
     && [ -f "$V/.ziyan_path_stats" ]; then
    # 探针已结束且有统计
    sleep 0.3
    break
  fi
  sleep 0.4
done
# 软停
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; chmod 666 "$V/.ziyan_kill_scripts"
sleep 1
LUA_N=$(ps -A -o command= 2>/dev/null | grep -c '[l]ua5.3' || true)
EMBED=$(test -f "$V/.ziyan_lua_embedded" && echo 1 || echo 0)
KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
SESSK=$(test -f "$V/.ziyan_session_keep" && echo 1 || echo 0)
STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)
CR_FIND=$(echo "$STATS" | sed -n 's/.*via_color_req_find=\([0-9][0-9]*\).*/\1/p')
EM_FIND=$(echo "$STATS" | sed -n 's/.*via_embed_find=\([0-9][0-9]*\).*/\1/p')
[ -z "$CR_FIND" ] && CR_FIND=-1
[ -z "$EM_FIND" ] && EM_FIND=-1
echo "STATS=$STATS"
echo "LUA5_N=$LUA_N EMBED_FLAG=$EMBED KEEP=$KEEP SESSION_KEEP=$SESSK COLOR_REQ_HITS=$REQ_HITS"
echo "via_embed_find=$EM_FIND via_color_req_find=$CR_FIND"
OK=1
# 包版本含 193+
echo "$VER" | grep -q '193' || { echo "FAIL ver_not_193"; OK=0; }
[ "$CR_FIND" = "0" ] || { echo "FAIL color_req_find=$CR_FIND"; OK=0; }
[ "$EM_FIND" -gt 0 ] 2>/dev/null || { echo "FAIL embed_find=$EM_FIND"; OK=0; }
[ "$LUA_N" = "0" ] || { echo "FAIL independent_lua=$LUA_N"; OK=0; }
[ "$KEEP" = "0" ] || { echo "FAIL sticky_keep=$KEEP"; OK=0; }
[ "$SESSK" = "0" ] || { echo "FAIL session_keep=$SESSK"; OK=0; }
[ "$REQ_HITS" = "0" ] || { echo "FAIL color_req_file_hits=$REQ_HITS"; OK=0; }
if [ "$OK" = 1 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
R
  } 
  if grep -q 'VERDICT=PASS' "$OUT/gate_${H}.txt" 2>/dev/null; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done

{
  echo "# E1 embed hotpath"
  echo "stamp=$STAMP sec=$SEC hosts=${HOSTS[*]}"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  if [ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -gt 0 ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -gt 0 ]
