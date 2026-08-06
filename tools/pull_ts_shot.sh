#!/bin/bash
# 从设备拉取 init(1) 逻辑横屏截图，供 TSColorPicker / ts_color_pick_gui 取色
set -e
HOST="${THEOS_DEVICE_IP:-192.168.31.166}"
PASS="${ZIYAN_SSH_PASS:-alpine}"
OUT="${1:-$(dirname "$0")/../layout/private/var/mobile/Media/ZiYan/ts_shot.png}"
VAR=/usr/lib/ziyan/var
REMOTE=/private/var/mobile/Media/ZiYan/ts_shot.png

SSHPASS=alpine
if command -v sshpass >/dev/null; then
  SSH="sshpass -e ssh -o StrictHostKeyChecking=accept-new"
  SCP="sshpass -e scp -o StrictHostKeyChecking=accept-new"
  export SSHPASS="$PASS"
else
  SSH="ssh"
  SCP="scp"
fi

echo "[pull] dumpScreen on $HOST ..."
$SSH "root@$HOST" "printf '1\n1136\n640\n' > $VAR/.ziyan_orient; rm -f $VAR/.ziyan_color_rep; printf 'dumpScreen\ndump1\n' > $VAR/.ziyan_color_req; for i in \$(seq 1 60); do [ -f $VAR/.ziyan_color_rep ] && break; sleep 0.05; done; cat $VAR/.ziyan_color_rep; ls -la $REMOTE"
mkdir -p "$(dirname "$OUT")"
$SCP "root@$HOST:$REMOTE" "$OUT"
echo "[pull] saved -> $OUT"
echo "[pull] 下一步: /usr/bin/python3 tools/ts_color_pick_gui.py \"$OUT\" --logic 1136x640"
