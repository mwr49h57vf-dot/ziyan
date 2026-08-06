#!/usr/bin/env bash
# StabilityAnalyzer host collector — JSONL to logs/stability/
# Devices: ZiYan test .166/.53 + optional compare TS .149/.171 (observe only)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/logs/stability"
PASS="${TSPASS:-alpine}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DAY="$(date +%Y%m%d)"
mkdir -p "$OUT"
JSONL="${OUT}/stability_${DAY}.jsonl"

emit() {
  # $1=ip $2=role $3=json_object_body_without_braces
  echo "{\"time\":\"${TS}\",\"device\":\"$1\",\"role\":\"$2\",$3}" >>"$JSONL"
}

collect_ziyan() {
  local IP=$1 ROOTPATH=$2
  local body
  body=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 "root@${IP}" "bash -s" <<EOS 2>/dev/null || true
ROOT=$ROOTPATH
VAR=\$ROOT/var
SB_PID=\$(ps aux | awk '/SpringBoard.app\\/SpringBoard/ && !/awk/ {print \$2; exit}')
SB_ET=\$(ps -o etime= -p \$SB_PID 2>/dev/null | tr -d ' ')
LUA_N=\$(ps aux | grep -c '[z]iyan_run.lua' || true)
ZOMB=\$(ps aux | awk '/lua5.3/ && /ziyan_run/ && \$4==\"0.0\" && \$6==\"0\" {c++} END{print c+0}')
PULSE=\$(cat \$VAR/.ziyan_stability_pulse 2>/dev/null | tr '\\n' ' ' | sed 's/\"/\\\\\"/g')
ORIENT=\$(head -1 \$VAR/.ziyan_orient 2>/dev/null)
MENU=\$(grep '^init=' \$VAR/.ziyan_menu_geom 2>/dev/null | head -1 | tr -d '\\n')
TOAST=\$(grep 'toastOrient=' \$VAR/.ziyan_toast_dump 2>/dev/null | head -1 | tr -d '\\n' | sed 's/\"/\\\\\"/g')
CRASH_N=\$(ls /var/mobile/Library/Logs/CrashReporter/*SpringBoard* 2>/dev/null | wc -l | tr -d ' ')
VAR_SZ=\$(du -sk \$VAR 2>/dev/null | awk '{print \$1}')
echo "sb_pid=\${SB_PID:-0};sb_etime=\${SB_ET:-};lua_n=\${LUA_N:-0};zombie_lua=\${ZOMB:-0};orient=\${ORIENT:-};menu=\\"\${MENU:-}\\";toast=\\"\${TOAST:-}\\";crash_n=\${CRASH_N:-0};var_kb=\${VAR_SZ:-0};pulse=\\"\${PULSE:-}\\""
EOS
)
  emit "$IP" "ziyan_test" "\"metrics\":\"${body//\"/\\\"}\""
}

collect_ts() {
  local IP=$1
  local body
  body=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 "root@${IP}" "bash -s" <<'EOS' 2>/dev/null || true
DAEM=$(ps aux | grep '[T]SDaemon' | head -1)
UP=$(uptime | tr -d '\n' | sed 's/"/\\"/g')
RSS=$(ps aux | awk '/[T]SDaemon/ {print $6; exit}')
ET=$(ps aux | awk '/[T]SDaemon/ {print $10; exit}')
LOG_N=$(wc -l </var/mobile/Media/TouchSprite/log/ts.log 2>/dev/null | tr -d ' ')
echo "daemon_rss_kb=${RSS:-0};daemon_time=${ET:-};ts_log_lines=${LOG_N:-0};uptime=${UP:-}"
EOS
)
  emit "$IP" "ts_observe" "\"metrics\":\"${body//\"/\\\"}\""
}

collect_ziyan 192.168.31.166 /usr/lib/ziyan
collect_ziyan 192.168.31.53 /var/jb/usr/lib/ziyan
collect_ts 192.168.31.149
collect_ts 192.168.31.171
echo "[StabilityAnalyzer] wrote $JSONL"
