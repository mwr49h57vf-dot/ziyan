#!/usr/bin/env bash
# P0：Find/Home 资源基线采样（.53/.112 默认；可选其它 ZiYan 机）
# 协议：清场 → Home → embed 找色循环 ~SEC 秒 → 期间每 ~2s 采样
#       RSS/CPU/FC_N/front/shm/seq/keep/force/relay/find_wall
# 用法: bash tools/zy_find_home_mem_sample.sh [53 112]   ZY_FH_SEC=100
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SEC="${ZY_FH_SEC:-100}"
if [ "$#" -eq 0 ]; then HOSTS=(53 112); else HOSTS=("$@"); fi
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/FIND_HOME_MEM_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

echo "OUT=$OUT SEC=$SEC hosts=${HOSTS[*]}" | tee "$OUT/OUT_PATH.txt"

sample_one() {
  local H="$1"
  local IP="192.168.31.$H"
  local SCHEME=rootful
  [ "$H" = "53" ] && SCHEME=rootless
  echo "==== sample .$H ${SEC}s ===="
  ssh_r "$IP" "SCHEME=$SCHEME SEC=$SEC H=$H bash -s" >"$OUT/sample_${H}.tsv" 2>"$OUT/sample_${H}.err" <<'R'
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var; B=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var; B=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
mkdir -p "$MEDIA" "$V"
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 1
rm -f "$V/.ziyan_embed_off" "$V/.ziyan_active" "$V/.ziyan_keep_daemon" \
  "$V/.ziyan_session_keep" "$V/.ziyan_force_recap" "$V/.ziyan_frame_req" \
  "$V/.ziyan_lua_embedded" "$V/.ziyan_embed_alive"
echo 1 >"$V/.ziyan_embed_on"; chmod 666 "$V/.ziyan_embed_on"
# 202：禁 kickstart -k
launchctl kickstart system/com.ziyan.framecap 2>/dev/null || \
  launchctl kickstart com.ziyan.framecap 2>/dev/null || true
sleep 1.2
for i in 1 2 3 4 5; do
  echo 1 >"$V/.ziyan_go_home"; sleep 0.7; rm -f "$V/.ziyan_go_home"
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "$F" | grep -qi springboard && break
done
echo 1 >"$V/.ziyan_force_recap"
echo "nonce=fh_a0" >"$V/.ziyan_frame_req"
sleep 1.5

cat >"$MEDIA/_fh_mem.lua" <<LUA
local deadline = (os.time() or 0) + $SEC
local n = 0
while (os.time() or 0) < deadline do
  n = n + 1
  if type(findMultiColorInRegionFuzzy) == "function" then
    findMultiColorInRegionFuzzy(0xFFFFFF, "", 90, 0, 0, 80, 80)
  end
  if type(mSleep) == "function" then mSleep(200)
  elseif type(ziyan_embed_msleep) == "function" then ziyan_embed_msleep(200) end
end
LUA
chmod 666 "$MEDIA/_fh_mem.lua"
rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop"
printf 'path=%s/_fh_mem.lua\nstop=0\n' "$MEDIA" >"$V/.ziyan_run_intent"
printf '%s/_fh_mem.lua\n' "$MEDIA" >"$V/.ziyan_embed_script"
echo "nonce=fh_${H}_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_go"

echo -e "t\tsb_pid\tsb_rss\tfc_n\tfc_rss\tfront\tshm_bid\tseq\tkeep\tres_bytes\tforce\trelay\twall_ms\tlife"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin:$PATH"
SB0=$(ps -axo pid,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
echo "META host=.$H VER=$VER SEC=$SEC SB0=${SB0:-0} start=$(date +%s)" >&2

end=$(( $(date +%s) + SEC + 5 ))
while [ "$(date +%s)" -lt "$end" ]; do
  now=$(date +%s)
  SB_LINE=$(ps -axo pid,rss,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1)
  SB_PID=$(echo "$SB_LINE" | sed 's/^ *//' | cut -d' ' -f1)
  SB_RSS=$(echo "$SB_LINE" | sed 's/^ *//' | tr -s ' ' | cut -d' ' -f2)
  FC_LINES=$(ps -axo pid,rss,args 2>/dev/null | grep '[z]iyan_framecap serve' || true)
  FC_N=$(echo "$FC_LINES" | grep -c . || true)
  FC_RSS=$(echo "$FC_LINES" | head -1 | sed 's/^ *//' | tr -s ' ' | cut -d' ' -f2)
  FRONT=""; [ -f "$V/.ziyan_front_bid" ] && FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid")
  SHM=""; [ -f "$V/.ziyan_shm_front_bid" ] && SHM=$(tr -d '\r\n' <"$V/.ziyan_shm_front_bid")
  SEQ=""; [ -f "$V/.ziyan_locked_seq" ] && SEQ=$(tr -d '\r\n' <"$V/.ziyan_locked_seq")
  RES=""; [ -f "$V/.ziyan_resident_bytes" ] && RES=$(tr -d '\r\n' <"$V/.ziyan_resident_bytes" | head -c 80)
  [ -z "$SEQ" ] && SEQ=$(echo "$RES" | sed -n 's/.*seq=\([0-9][0-9]*\).*/\1/p')
  KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
  FORCE=$(test -f "$V/.ziyan_force_recap" && echo 1 || echo 0)
  RELAY=$(test -f "$V/.ziyan_relay_req" && echo 1 || echo 0)
  WALL=""; [ -f "$V/.ziyan_color_perf" ] && WALL=$(tr '\n' ' ' <"$V/.ziyan_color_perf" | head -c 60)
  LIFE=""; [ -f "$V/.ziyan_frame_lifecycle" ] && LIFE=$(tr -d '\r\n' <"$V/.ziyan_frame_lifecycle" | head -c 40)
  echo -e "${now}\t${SB_PID:-0}\t${SB_RSS:-0}\t${FC_N:-0}\t${FC_RSS:-0}\t${FRONT}\t${SHM}\t${SEQ}\t${KEEP}\t${RES}\t${FORCE}\t${RELAY}\t${WALL}\t${LIFE}"
  # 中段一次 Home 扰动（约 40%）
  elapsed=$(( now - (end - SEC - 5) ))
  if [ "$elapsed" -ge $((SEC * 4 / 10)) ] && [ "$elapsed" -lt $((SEC * 4 / 10 + 3)) ]; then
    echo 1 >"$V/.ziyan_go_home"
    sleep 0.8
    rm -f "$V/.ziyan_go_home"
  fi
  sleep 2
done

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; sleep 2
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon" 2>/dev/null
SB1=$(ps -axo pid,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
echo "META end=$(date +%s) SB1=${SB1:-0} SB_CHG=$([ "${SB0:-0}" != "${SB1:-0}" ] && echo 1 || echo 0)" >&2
R
}

for H in "${HOSTS[@]}"; do
  sample_one "$H" &
done
wait || true

{
  echo "# FIND/HOME mem baseline"
  echo "stamp=$STAMP sec=$SEC hosts=${HOSTS[*]}"
  echo ""
  for H in "${HOSTS[@]}"; do
    f="$OUT/sample_${H}.tsv"
    echo "## .$H"
    if [ ! -s "$f" ]; then echo "MISSING"; continue; fi
    # 跳过表头取 rss
    awk -F'\t' 'NR>1 && $5+0>0 {n++; if(n==1){r0=$5;s0=$3} r1=$5;s1=$3; if($5+0>rmax)rmax=$5+0; if($4+0>fcn)fcn=$4+0}
      END{printf "fc_rss0=%s fc_rss1=%s fc_rss_delta_kb=%d fc_rss_max=%s fc_n_max=%s sb_rss0=%s sb_rss1=%s samples=%d\n", r0,r1,(r1-r0),rmax,fcn,s0,s1,n}' "$f"
    grep '^META' "$OUT/sample_${H}.err" 2>/dev/null || true
    echo ""
  done
} | tee "$OUT/VERDICT.md"

echo "OUT=$OUT"
