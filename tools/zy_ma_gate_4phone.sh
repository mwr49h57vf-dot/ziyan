#!/usr/bin/env bash
# M-A 门禁：清场后启业务脚本，采 FC_N / shm / color_perf / force 日志 / CPU
# 铁律：开头必须跑 zy_pretest_clean_4phone.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/MA_GATE_129_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "======== PRETEST CLEAN (铁律) ========"
bash tools/zy_pretest_clean_4phone.sh | tee "$OUT/pretest_clean.txt"

DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"

launch_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4"
  local media=/var/mobile/Media/ZiYan/lua
  local src="$DESKTOP_IOS7"
  [ "$script" = ios8p.lua ] && src="$DESKTOP_IOS8P"
  scp_r "$src" "$ip" "$media/$script"
  ssh_r "$ip" "SCHEME=$scheme SCRIPT=$script bash -s" <<'EOS' | tee "$OUT/launch_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  MEDIA=/var/mobile/Media/ZiYan
else
  VAR=/usr/lib/ziyan/var
  MEDIA=/var/mobile/Media/ZiYan
fi
rm -f "$VAR/.ziyan_stop"
echo 1 >"$VAR/.ziyan_run_intent"
echo 1 >"$VAR/.ziyan_embed_on"
# 走 App/音量同源：写 embed 脚本路径 + go
SCRIPT_PATH="$MEDIA/lua/$SCRIPT"
echo -n "$SCRIPT_PATH" >"$VAR/.ziyan_embed_script"
chmod 666 "$VAR/.ziyan_embed_script" "$VAR/.ziyan_run_intent" 2>/dev/null
echo 1 >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_embed_go" 2>/dev/null
# 截断日志便于计数
: >"$VAR/.ziyan_framecap_log" 2>/dev/null || true
sleep 2
FC=$(ps -A -o command= | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
EM=$(cat "$VAR/.ziyan_embed_alive" 2>/dev/null | head -1)
PERF=$(cat "$VAR/.ziyan_color_perf" 2>/dev/null | head -1)
echo "LAUNCH tag=$SCHEME FC_N=$FC embed=$EM perf=$PERF script=$SCRIPT_PATH"
EOS
}

echo "======== LAUNCH SCRIPTS ========"
launch_one 53 192.168.31.53 rootless ios8p.lua &
launch_one 101 192.168.31.101 rootful ios7.lua &
launch_one 112 192.168.31.112 rootful ios7.lua &
launch_one 166 192.168.31.166 rootful ios7.lua &
wait
echo "wait 25s settle..."
sleep 25

sample_one() {
  local tag="$1" ip="$2" scheme="$3"
  ssh_r "$ip" "SCHEME=$scheme TAG=$tag bash -s" <<'EOS' | tee "$OUT/sample_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
else
  VAR=/usr/lib/ziyan/var
fi
FC_N=$(ps -A -o command= | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
Z_N=$(ps -A -o state= | grep -c Z || true)
LUA_N=$(ps -A -o command= | grep -E 'ziyan_run\.lua|ios7|ios8p' | grep -v grep | wc -l | tr -d ' ')
SHM=$(ls -l "$VAR/.ziyan_frame_shm" 2>/dev/null | sed 's/^ *//' | tr -s ' ' | cut -d' ' -f5)
KEEP=$(test -f "$VAR/.ziyan_keep_daemon" && echo 1 || echo 0)
BID=$(cat "$VAR/.ziyan_front_bid" 2>/dev/null | head -1)
SHM_BID=$(cat "$VAR/.ziyan_shm_front_bid" 2>/dev/null | head -1)
PERF=$(cat "$VAR/.ziyan_color_perf" 2>/dev/null | head -1)
PKG=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
CPU=$(ps -A -o %cpu=,command= | grep 'ziyan_framecap serve' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
RSS=$(ps -A -o rss=,command= | grep 'ziyan_framecap serve' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
FORCE=$(grep -cE 'home_force_recap|force_recap\+|home_force_flush|force_flush' "$VAR/.ziyan_framecap_log" 2>/dev/null || echo 0)
RELAY=$(grep -c 'relay_req' "$VAR/.ziyan_framecap_log" 2>/dev/null || echo 0)
SKIP=$(grep -cE 'force_skip_hot_aligned|force_quiet_skip|black_backoff' "$VAR/.ziyan_framecap_log" 2>/dev/null || echo 0)
INPLACE=$(grep -c 'shm_invalidate' "$VAR/.ziyan_framecap_log" 2>/dev/null || echo 0)
echo "TAG=$TAG PKG=$PKG FC_N=$FC_N Z_N=$Z_N LUA_N=$LUA_N SHM=$SHM KEEP=$KEEP"
echo "FRONT=$BID SHM_BID=$SHM_BID CPU=$CPU RSS_KB=$RSS"
echo "PERF=$PERF"
echo "FORCE_N=$FORCE RELAY_N=$RELAY SKIP_N=$SKIP INV_N=$INPLACE"
# 门禁粗判
OK=1
[ "$FC_N" = "1" ] || { echo "FAIL FC_N=$FC_N"; OK=0; }
[ "${Z_N:-0}" -le 2 ] || { echo "FAIL Z_N=$Z_N"; OK=0; }
[ -n "$SHM" ] && [ "$SHM" -gt 1000 ] || { echo "FAIL SHM=$SHM"; OK=0; }
echo "$PERF" | grep -q 'avg_wall_ms=' || { echo "WARN no color_perf yet"; }
[ "$OK" = 1 ] && echo "GATE_PARTIAL=PASS" || echo "GATE_PARTIAL=FAIL"
EOS
}

echo "======== SAMPLE ========"
sample_one 53 192.168.31.53 rootless &
sample_one 101 192.168.31.101 rootful &
sample_one 112 192.168.31.112 rootful &
sample_one 166 192.168.31.166 rootful &
wait

{
  echo "# M-A GATE 129"
  echo
  for t in 53 101 112 166; do
    echo "## .$t"
    grep -E 'TAG=|GATE_PARTIAL|FAIL|PERF=|FORCE_N=|PKG=' "$OUT/sample_${t}.txt" || true
    echo
  done
  PASS=1
  for t in 53 101 112 166; do
    grep -q 'GATE_PARTIAL=PASS' "$OUT/sample_${t}.txt" || PASS=0
  done
  if [ "$PASS" = 1 ]; then
    echo "## OVERALL=PASS (partial: FC_N=1 + shm + 无僵尸洪峰；TINY 需人工 Home 窗确认)"
  else
    echo "## OVERALL=FAIL"
  fi
} | tee "$OUT/VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
# exit code for CI
grep -q 'OVERALL=PASS' "$OUT/VERDICT.md"
