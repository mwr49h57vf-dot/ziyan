#!/bin/bash
# 8-161-44：找色离 SB 后四机 vs .171 长稳采样（观察向；不部署 .171）
# 用法: bash tools/ziyan_find_sb_leave_bench.sh [seconds=300]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEC="${1:-300}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$ROOT/tmp_shots/FIND_SB_LEAVE_${STAMP}"
mkdir -p "$OUT"
PASS=alpine
ZIYAN_IPS=(53 101 112 166)
TS_IP=171

ssh_q() {
  local ip="$1"; shift
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    -o UserKnownHostsFile=/dev/null "root@192.168.31.$ip" "$@" 2>/dev/null
}

sample_ziyan() {
  local ip="$1" tag="$2"
  ssh_q "$ip" 'bash -s' <<'EOS' >"$OUT/${tag}.txt" || true
VAR=/usr/lib/ziyan/var
[ -d /var/jb/usr/lib/ziyan/var ] && VAR=/var/jb/usr/lib/ziyan/var
echo "===META==="
date
dpkg-query -W -f='${Version}\n' com.ziyan.ziyan 2>/dev/null || true
echo "===FLAGS==="
for f in .ziyan_zero_sb_full .ziyan_find_sb_banned .ziyan_keep_daemon .ziyan_sb_vol_thin; do
  [ -f "$VAR/$f" ] && echo "$f=1" || echo "$f=0"
done
echo "===FIND==="
cat "$VAR/.ziyan_find_via" 2>/dev/null | tr '\n' ' '; echo
cat "$VAR/.ziyan_color_perf" 2>/dev/null | head -c 400; echo
echo "===SB==="
ps -A -o pid=,etime=,rss=,pcpu=,command= 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1
echo "===FRAMECAP==="
ps -A -o pid=,etime=,rss=,pcpu=,command= 2>/dev/null | grep ziyan_framecap | grep -v grep | head -2
echo "===LUA==="
ps -A -o pid=,etime=,rss=,pcpu=,command= 2>/dev/null | grep ziyan_run.lua | grep -v grep | head -3
echo "===DAEMON==="
ps -A -o pid=,etime=,rss=,pcpu=,command= 2>/dev/null | grep ziyadaemond | grep -v grep | head -1
echo "===CRASH==="
ls -lt /var/mobile/Library/Logs/CrashReporter/*SpringBoard* 2>/dev/null | head -3 || echo none
EOS
}

sample_ts() {
  local tag="$1"
  ssh_q "$TS_IP" 'bash -s' <<'EOS' >"$OUT/${tag}.txt" || true
echo "===META==="
date
echo "===SB==="
ps -A -o pid=,etime=,rss=,pcpu=,command= 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1
echo "===TSDAEMON==="
ps -A -o pid=,etime=,rss=,pcpu=,command= 2>/dev/null | grep -i TSDaemon | grep -v grep | head -2
echo "===TSTWEAK==="
ps -A -o pid=,etime=,rss=,pcpu=,command= 2>/dev/null | grep -i TouchSprite | grep -v grep | head -3
echo "===CRASH==="
ls -lt /var/mobile/Library/Logs/CrashReporter/*SpringBoard* 2>/dev/null | head -3 || echo none
EOS
}

echo "OUT=$OUT SEC=$SEC" | tee "$OUT/path.txt"
# t0
for ip in "${ZIYAN_IPS[@]}"; do sample_ziyan "$ip" "t0_ziyan_$ip"; done
sample_ts "t0_ts_$TS_IP"

# mid samples every 60s
ELAPSED=0
IDX=1
while [ "$ELAPSED" -lt "$SEC" ]; do
  SLEEP=60
  LEFT=$((SEC - ELAPSED))
  [ "$LEFT" -lt "$SLEEP" ] && SLEEP=$LEFT
  sleep "$SLEEP"
  ELAPSED=$((ELAPSED + SLEEP))
  for ip in "${ZIYAN_IPS[@]}"; do sample_ziyan "$ip" "t${IDX}_ziyan_$ip"; done
  sample_ts "t${IDX}_ts_$TS_IP"
  IDX=$((IDX + 1))
done

# synthesize rough verdict scaffold
{
  echo "# VERDICT FIND_SB_LEAVE $STAMP"
  echo
  echo "- Version target: 0.0.92-8-161-44"
  echo "- Sample window: ${SEC}s"
  echo "- Architecture: Daemon keepScreen + ROI find; \`.ziyan_find_sb_banned\`"
  echo "- Devices: ZiYan .53/.101/.112/.166 vs TS observe-only .171"
  echo
  echo "## Raw samples"
  echo "See \`t*_ziyan_*.txt\` / \`t*_ts_171.txt\` in this directory."
  echo
  echo "## Gate (manual fill after inspect)"
  echo "- [ ] find_via on all four is daemon|ncnn (never sb)"
  echo "- [ ] keep_daemon appears under script load"
  echo "- [ ] ZiYan SB rss max ≤ TS SB rss max during same window"
  echo "- [ ] No new SpringBoard crash on ZiYan four"
  echo "- [ ] Only then claim SB stability exceeds TouchSprite"
} >"$OUT/VERDICT_FIND_SB_LEAVE.md"

echo "DONE $OUT"
