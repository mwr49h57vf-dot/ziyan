#!/usr/bin/env bash
# 只读观察 .149/.171 触动：TSDaemon/SB RSS、脚本态、IOSurface 线索
# 禁止部署 ZiYan。用法: bash tools/zy_ts_obs_snapshot.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/TS_OBS/${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

snap() {
  local H="$1"
  local IP="192.168.31.$H"
  echo "==== TS obs .$H ===="
  ssh_r "$IP" bash -s >"$OUT/ts_${H}.txt" 2>&1 <<'R' || echo "SSH_FAIL .$H" | tee -a "$OUT/ts_${H}.txt"
set +e
echo "host=$(hostname) date=$(date +%s)"
echo "---- procs ----"
ps -axo pid,rss,%cpu,etime,args 2>/dev/null | grep -E 'TSDaemon|SpringBoard.app/SpringBoard|TouchSprite' | grep -v grep | head -20
echo "---- TS paths ----"
for p in /var/mobile/Media/TouchSprite/log /var/mobile/Media/TouchSprite \
  /var/mobile/Library/TouchSprite /usr/local/TouchSprite; do
  [ -e "$p" ] && ls -la "$p" 2>/dev/null | head -8
done
echo "---- vm_stat ----"
vm_stat 2>/dev/null | head -12
echo "---- iosurface_hint ----"
# 无 Frida：仅从 vmmap/heap 线索粗看（可能无权限）
PID=$(ps -axo pid,args 2>/dev/null | grep '[T]SDaemon -server' | head -1 | sed 's/^ *//' | cut -d' ' -f1)
echo "TSDaemon_pid=${PID:-0}"
if [ -n "${PID:-}" ] && [ "$PID" != "0" ]; then
  # footprint 类：若有 malloc_history/vmmap
  which vmmap >/dev/null 2>&1 && vmmap "$PID" 2>/dev/null | grep -iE 'IOSurface|TOTAL|dirty' | head -20
  ls -la /tmp 2>/dev/null | grep -iE 'touch|ts|sprite' | head -10
fi
echo "---- done ----"
R
}

for H in 149 171; do snap "$H"; done
{
  echo "# TS observe snapshot (read-only)"
  echo "stamp=$STAMP"
  echo "hosts=149 171"
  for H in 149 171; do
    echo ""
    echo "## .$H"
    grep -E 'TSDaemon|SpringBoard|TSDaemon_pid|host=' "$OUT/ts_${H}.txt" | head -20 || true
  done
} | tee "$OUT/SUMMARY.md"
echo "OUT=$OUT"
