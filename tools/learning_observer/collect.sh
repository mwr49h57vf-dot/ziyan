#!/usr/bin/env bash
# LearningObserver collector — host-side, read-only SSH to TS devices.
# Usage: bash tools/learning_observer/collect.sh
# NEVER deploys ZiYan; NEVER modifies TouchSprite files.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/logs/touchsprite_learning"
PASS="${TSPASS:-alpine}"
DEVICES=(192.168.31.149 192.168.31.171)
mkdir -p "$OUT"
TS="$(date +%Y%m%d_%H%M%S)"

for IP in "${DEVICES[@]}"; do
  F="${OUT}/${IP}_snapshot_${TS}.txt"
  echo "[LearningObserver] collect $IP → $F"
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 "root@${IP}" 'bash -s' >"$F" 2>&1 <<'EOS' || true
echo "=== META ==="
date; uname -a; sw_vers 2>/dev/null | head -3
echo "=== TSDaemon ==="
ps aux | grep -iE 'TSDaemon|Hades|TouchSprite' | grep -v grep
echo "=== uptime ==="; uptime
echo "=== run.cfg ==="; cat /var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null
echo "=== screen.cfg ==="; xxd /var/mobile/Media/TouchSprite/config/screen.cfg 2>/dev/null | head -5
echo "=== selectLUA ==="
grep -A1 selectLUA /var/mobile/Media/TouchSprite/config/config.plist 2>/dev/null | head -5
echo "=== ts.log tail ==="
tail -120 /var/mobile/Media/TouchSprite/log/ts.log 2>/dev/null
echo "=== err.log tail ==="
tail -60 /var/mobile/Media/TouchSprite/log/err.log 2>/dev/null
echo "=== OBSERVE_ONLY ==="
EOS
  # JSONL index line
  echo "{\"time\":\"${TS}\",\"device\":\"${IP}\",\"file\":\"$(basename "$F")\",\"kind\":\"snapshot\",\"role\":\"ts_observe_only\"}" \
    >>"${OUT}/index.jsonl"
done
echo "[LearningObserver] done"
