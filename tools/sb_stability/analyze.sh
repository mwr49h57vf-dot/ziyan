#!/usr/bin/env bash
# SpringBoardStabilityAnalyzer — SB 重启专项采集 → logs/sb_restart/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/logs/sb_restart"
PASS="${TSPASS:-alpine}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DAY="$(date +%Y%m%d)"
mkdir -p "$OUT"
JSONL="${OUT}/sb_${DAY}.jsonl"

collect() {
  local IP=$1 ZROOT=$2
  local body
  body=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=12 "root@${IP}" "bash -s" <<EOS 2>/dev/null || true
VAR=$ZROOT/var
SB_LINE=\$(ps -A -o pid,rss,vsz,%cpu,%mem,etime,command 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1)
LUA_LINE=\$(ps -A -o pid,rss,vsz,%cpu,%mem,etime,command 2>/dev/null | grep 'ziyan_run.lua' | grep -v grep | head -3)
LUA_N=\$(ps -A | grep -c '[z]iyan_run.lua' || true)
# crash / jetsam
CRASH_N=\$(ls /var/mobile/Library/Logs/CrashReporter/*SpringBoard* 2>/dev/null | wc -l | tr -d ' ')
JETSAM_N=\$(ls /var/mobile/Library/Logs/CrashReporter/*jetsam* /var/mobile/Library/Logs/CrashReporter/*Jetsam* 2>/dev/null | wc -l | tr -d ' ')
EXC_N=\$(ls /var/mobile/Library/Logs/CrashReporter/*ExcResource* 2>/dev/null | wc -l | tr -d ' ')
LATEST_CRASH=\$(ls -t /var/mobile/Library/Logs/CrashReporter/*SpringBoard* 2>/dev/null | head -1)
LATEST_JET=\$(ls -t /var/mobile/Library/Logs/CrashReporter/*jetsam* /var/mobile/Library/Logs/CrashReporter/*Jetsam* /var/mobile/Library/Logs/CrashReporter/*ExcResource* 2>/dev/null | head -1)
# counters from var if present
FIND_N=\$(grep -c 'event=find' \$VAR/.ziyan_coord_diag 2>/dev/null || echo 0)
TAP_N=\$(grep -c 'event=tap' \$VAR/.ziyan_coord_diag 2>/dev/null || echo 0)
PULSE=\$(cat \$VAR/.ziyan_stability_pulse 2>/dev/null | tr '\\n' ';' | sed 's/"/\\\\"/g')
# var size (image cache proxy)
VAR_KB=\$(du -sk \$VAR 2>/dev/null | awk '{print \$1}')
SHOT_N=\$(ls \$VAR/*.png \$VAR/ZYCV 2>/dev/null | wc -l | tr -d ' ')
# recent syslog lines mentioning SpringBoard / jetsam / memory
LOG_HIT=\$(grep -iE 'jetsam|SpringBoard.*killed|per-process-limit|ExcResource' /var/log/syslog 2>/dev/null | tail -5 | tr '\\n' '|' | sed 's/"/\\\\"/g')
# DiagnosticReports
DR=\$(ls -t /var/mobile/Library/Logs/CrashReporter/*.ips 2>/dev/null | head -3 | tr '\\n' ',' )
echo "SB=\${SB_LINE}"
echo "LUA=\${LUA_LINE}"
echo "LUA_N=\${LUA_N}"
echo "CRASH_N=\${CRASH_N}"
echo "JETSAM_N=\${JETSAM_N}"
echo "EXC_N=\${EXC_N}"
echo "LATEST_CRASH=\${LATEST_CRASH}"
echo "LATEST_JET=\${LATEST_JET}"
echo "FIND_N=\${FIND_N}"
echo "TAP_N=\${TAP_N}"
echo "VAR_KB=\${VAR_KB}"
echo "SHOT_N=\${SHOT_N}"
echo "PULSE=\${PULSE}"
echo "LOG_HIT=\${LOG_HIT}"
echo "DR=\${DR}"
# peek jetsam reason if file readable
if [ -n "\$LATEST_JET" ] && [ -f "\$LATEST_JET" ]; then
  echo "JET_PEEK=\$(head -c 800 \$LATEST_JET | tr '\\n' ' ' | sed 's/\"/\\\\\"/g')"
fi
EOS
)
  local SB LUA LUA_N CRASH_N JETSAM_N EXC_N FIND_N TAP_N VAR_KB SHOT_N PULSE LOG_HIT LATEST_JET JET_PEEK
  SB=$(echo "$body" | sed -n 's/^SB=//p' | head -1 | sed 's/"/\\"/g')
  LUA=$(echo "$body" | sed -n 's/^LUA=//p' | head -1 | sed 's/"/\\"/g')
  LUA_N=$(echo "$body" | sed -n 's/^LUA_N=//p' | head -1)
  CRASH_N=$(echo "$body" | sed -n 's/^CRASH_N=//p' | head -1)
  JETSAM_N=$(echo "$body" | sed -n 's/^JETSAM_N=//p' | head -1)
  EXC_N=$(echo "$body" | sed -n 's/^EXC_N=//p' | head -1)
  FIND_N=$(echo "$body" | sed -n 's/^FIND_N=//p' | head -1)
  TAP_N=$(echo "$body" | sed -n 's/^TAP_N=//p' | head -1)
  VAR_KB=$(echo "$body" | sed -n 's/^VAR_KB=//p' | head -1)
  SHOT_N=$(echo "$body" | sed -n 's/^SHOT_N=//p' | head -1)
  PULSE=$(echo "$body" | sed -n 's/^PULSE=//p' | head -1 | sed 's/"/\\"/g')
  LOG_HIT=$(echo "$body" | sed -n 's/^LOG_HIT=//p' | head -1 | sed 's/"/\\"/g')
  LATEST_JET=$(echo "$body" | sed -n 's/^LATEST_JET=//p' | head -1 | sed 's/"/\\"/g')
  JET_PEEK=$(echo "$body" | sed -n 's/^JET_PEEK=//p' | head -1 | sed 's/"/\\"/g')
  echo "{\"time\":\"${TS}\",\"device\":\"${IP}\",\"sb\":\"${SB}\",\"lua\":\"${LUA}\",\"lua_n\":${LUA_N:-0},\"crash_n\":${CRASH_N:-0},\"jetsam_n\":${JETSAM_N:-0},\"exc_n\":${EXC_N:-0},\"find_n\":\"${FIND_N:-0}\",\"tap_n\":\"${TAP_N:-0}\",\"var_kb\":${VAR_KB:-0},\"shot_n\":${SHOT_N:-0},\"pulse\":\"${PULSE}\",\"log_hit\":\"${LOG_HIT}\",\"latest_jet\":\"${LATEST_JET}\",\"jet_peek\":\"${JET_PEEK}\"}" >>"$JSONL"
  printf '%s\n' "$body" > "${OUT}/raw_${IP//./_}_${DAY}.txt"
}

collect 192.168.31.166 /usr/lib/ziyan
collect 192.168.31.53 /var/jb/usr/lib/ziyan
# TS observe-only (daemon RSS contrast; no ZiYan deploy)
for IP in 192.168.31.149 192.168.31.171; do
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 "root@${IP}" \
    "ps aux | grep '[T]SDaemon' | head -1; uptime" \
    > "${OUT}/ts_${IP//./_}_${DAY}.txt" 2>/dev/null || true
done
echo "[SpringBoardStabilityAnalyzer] wrote $JSONL"
