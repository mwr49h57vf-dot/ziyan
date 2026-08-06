#!/usr/bin/env bash
# ScreenMirrorDiagnostic host collector → logs/screen_mirror/*.jsonl
# 不改用户脚本；从设备 var 采样 Screen Mirror 管线字段
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/logs/screen_mirror"
PASS="${TSPASS:-alpine}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DAY="$(date +%Y%m%d)"
mkdir -p "$OUT"
JSONL="${OUT}/mirror_${DAY}.jsonl"

sample_one() {
  local IP=$1 ZROOT=$2
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 "root@${IP}" "bash -s" <<EOS 2>/dev/null || true
VAR=$ZROOT/var
SI=\$(cat \$VAR/.ziyan_screen_info 2>/dev/null | tr '\\n' ' ')
NW=\$(cat \$VAR/.ziyan_native_wh 2>/dev/null | tr '\\n' ',')
OR=\$(cat \$VAR/.ziyan_orient 2>/dev/null | tr '\\n' ',')
TD=\$(grep -E 'rawLand=|mode=|host=|raw=|logic=' \$VAR/.ziyan_toast_dump 2>/dev/null | head -2 | tr '\\n' ' ')
TP=\$(cat \$VAR/.ziyan_tap_proof 2>/dev/null | tr '\\n' ' ')
CD=\$(tail -1 \$VAR/.ziyan_coord_diag 2>/dev/null | tr '\\n' ' ')
ALIVE=\$([ -f \$VAR/.ziyan_app_alive ] && echo 1 || echo 0)
# parse screen_info: src=WxH logicBuf=WxH scale=N
echo "SI=\${SI}"
echo "NW=\${NW}"
echo "OR=\${OR}"
echo "TD=\${TD}"
echo "TP=\${TP}"
echo "CD=\${CD}"
echo "ALIVE=\${ALIVE}"
EOS
}

emit_device() {
  local IP=$1 ZROOT=$2
  local raw
  raw=$(sample_one "$IP" "$ZROOT")
  local SI NW OR TD TP CD ALIVE
  SI=$(echo "$raw" | sed -n 's/^SI=//p' | head -1 | sed 's/"/\\"/g')
  NW=$(echo "$raw" | sed -n 's/^NW=//p' | head -1 | sed 's/"/\\"/g')
  OR=$(echo "$raw" | sed -n 's/^OR=//p' | head -1 | sed 's/"/\\"/g')
  TD=$(echo "$raw" | sed -n 's/^TD=//p' | head -1 | sed 's/"/\\"/g')
  TP=$(echo "$raw" | sed -n 's/^TP=//p' | head -1 | sed 's/"/\\"/g')
  CD=$(echo "$raw" | sed -n 's/^CD=//p' | head -1 | sed 's/"/\\"/g')
  ALIVE=$(echo "$raw" | sed -n 's/^ALIVE=//p' | head -1)
  # extract dims
  local srcW srcH bufW bufH scale
  srcW=$(echo "$SI" | sed -n 's/.*src=\([0-9]*\)x.*/\1/p')
  srcH=$(echo "$SI" | sed -n 's/.*src=[0-9]*x\([0-9]*\).*/\1/p')
  bufW=$(echo "$SI" | sed -n 's/.*logicBuf=\([0-9]*\)x.*/\1/p')
  bufH=$(echo "$SI" | sed -n 's/.*logicBuf=[0-9]*x\([0-9]*\).*/\1/p')
  scale=$(echo "$SI" | sed -n 's/.*scale=\([0-9.]*\).*/\1/p')
  local orient
  orient=$(echo "$OR" | cut -d, -f1)
  echo "{\"time\":\"${TS}\",\"device\":\"${IP}\",\"orientation\":\"${orient:-}\",\"screenWidth\":\"${srcW:-}\",\"screenHeight\":\"${srcH:-}\",\"bufferWidth\":\"${bufW:-}\",\"bufferHeight\":\"${bufH:-}\",\"scale\":\"${scale:-}\",\"native\":\"${NW}\",\"toast\":\"${TD}\",\"touch\":\"${TP}\",\"vision\":\"${CD}\",\"app_alive\":${ALIVE:-0},\"result\":\"sampled\"}" >>"$JSONL"
}

emit_device 192.168.31.166 /usr/lib/ziyan
emit_device 192.168.31.53 /var/jb/usr/lib/ziyan
echo "[ScreenMirrorDiagnostic] wrote $JSONL"
