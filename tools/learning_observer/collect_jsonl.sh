#!/usr/bin/env bash
# LearningObserver — JSONL events from TS devices (read-only)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/logs/touchsprite_learning"
PASS="${TSPASS:-alpine}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DAY="$(date +%Y%m%d)"
mkdir -p "$OUT"
JSONL="${OUT}/learning_${DAY}.jsonl"
DEVICES=(192.168.31.149 192.168.31.171)

for IP in "${DEVICES[@]}"; do
  SNAP="${OUT}/${IP}_snapshot_$(date +%Y%m%d_%H%M%S).txt"
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 "root@${IP}" 'bash -s' >"$SNAP" 2>&1 <<'EOS' || true
echo "=== META ==="; date; uname -a; sw_vers 2>/dev/null | head -3
echo "=== TSDaemon ==="; ps aux | grep -iE 'TSDaemon|Hades' | grep -v grep
echo "=== uptime ==="; uptime
echo "=== run.cfg ==="; cat /var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null
echo "=== selectLUA ==="; grep -A1 selectLUA /var/mobile/Media/TouchSprite/config/config.plist 2>/dev/null | head -4
echo "=== ts.log tail ==="; tail -80 /var/mobile/Media/TouchSprite/log/ts.log 2>/dev/null
echo "=== err.log tail ==="; tail -40 /var/mobile/Media/TouchSprite/log/err.log 2>/dev/null
EOS
  SCRIPT=$(grep -A1 selectLUA "$SNAP" 2>/dev/null | tail -1 | sed 's/<[^>]*>//g' | tr -d '\t ' || true)
  STATE="running"
  grep -q 'TSDaemon' "$SNAP" || STATE="idle"
  ERR=$(grep 'Lua运行错误' "$SNAP" | tail -1 | sed 's/"/\\"/g' || true)
  echo "{\"time\":\"${TS}\",\"device\":\"${IP}\",\"script\":\"${SCRIPT}\",\"function\":\"\",\"args\":\"\",\"returns\":\"\",\"coords\":\"\",\"screen_size\":\"\",\"orientation\":\"\",\"run_state\":\"${STATE}\",\"error\":\"${ERR}\",\"lifecycle\":\"snapshot=$(basename "$SNAP")\",\"role\":\"ts_observe_only\"}" >>"$JSONL"
done
echo "[LearningObserver] JSONL → $JSONL"
