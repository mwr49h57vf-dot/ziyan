#!/usr/bin/env bash
# DeviceDifferenceAnalyzer — 双机差异采集（仅第二类 .166/.53）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${ROOT}/logs/device_difference"
PASS="${TSPASS:-alpine}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DAY="$(date +%Y%m%d)"
mkdir -p "$OUT_DIR"
JSONL="${OUT_DIR}/diff_${DAY}.jsonl"

ssh_root() {
  local IP=$1; shift
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=12 "root@${IP}" "$@"
}

probe() {
  local IP=$1 ZROOT=$2 TAG=$3
  local body
  body=$(ssh_root "$IP" "bash -s" <<EOS 2>/dev/null || true
Z=$ZROOT
VAR=\$Z/var
echo "===SCREEN==="; cat \$VAR/.ziyan_screen_info 2>/dev/null
echo "===NATIVE==="; cat \$VAR/.ziyan_native_wh 2>/dev/null
echo "===ORIENT==="; cat \$VAR/.ziyan_orient 2>/dev/null
echo "===TOAST==="; cat \$VAR/.ziyan_toast_dump 2>/dev/null | head -4
echo "===TAP==="; cat \$VAR/.ziyan_tap_proof 2>/dev/null
echo "===MEM==="; ps -A -o pid,rss,vsz,etime,command 2>/dev/null | grep -E 'SpringBoard.app/SpringBoard|ziyan_run' | grep -v grep | head -6
echo "===JB==="; [ -d /var/jb ] && echo rootless || echo rootful
EOS
)
  printf '%s\n' "$body" > "${OUT_DIR}/${TAG}_${DAY}.txt"
  local screen native
  screen=$(echo "$body" | awk '/===SCREEN===/{getline; print; exit}' | sed 's/"/\\"/g')
  native=$(echo "$body" | awk '/===NATIVE===/{getline; a=$0; getline; print a","$0; exit}' | sed 's/"/\\"/g')
  echo "{\"time\":\"${TS}\",\"device\":\"${IP}\",\"tag\":\"${TAG}\",\"screen\":\"${screen}\",\"native\":\"${native}\"}" >>"$JSONL"
}

probe 192.168.31.166 /usr/lib/ziyan ios7
probe 192.168.31.53 /var/jb/usr/lib/ziyan ios8p
echo "[DeviceDifferenceAnalyzer] wrote $JSONL"
