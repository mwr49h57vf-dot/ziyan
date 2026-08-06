#!/usr/bin/env bash
# 8-147：四机 P2 指标抽样（截屏/找色/触控/RSS）
set -euo pipefail
OUT="${1:-tmp_shots/SURPASS_TS/8147_p2_metrics}"
mkdir -p "$OUT"
PASS=alpine
sample() {
  local tag=$1 ip=$2 scheme=$3
  local root=/usr/lib/ziyan
  [ "$scheme" = rootless ] && root=/var/jb/usr/lib/ziyan
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o ConnectTimeout=15 "root@$ip" "bash -s" <<EOS
set +e
VAR=$root/var
echo PKG=\$(dpkg-query -W -f='\${Version}' com.ziyan.ziyan 2>/dev/null)
echo COLOR=\$(cat \$VAR/.ziyan_color_perf 2>/dev/null)
echo HID=\$(cat \$VAR/.ziyan_hid_perf 2>/dev/null)
echo HOOK=\$(cat \$VAR/.ziyan_frame_hook_alive 2>/dev/null)
echo P2=\$(cat \$VAR/.ziyan_p2_perf 2>/dev/null)
echo FINDVIA=\$(cat \$VAR/.ziyan_find_via 2>/dev/null)
echo NEON_OFF=\$(test -f \$VAR/.ziyan_color_neon_off && echo 1 || echo 0)
echo UNIFIED=\$(cat \$VAR/.ziyan_unified_dispatch 2>/dev/null)
echo ICON_DAEMON=\$(grep icon_edge \$VAR/.ziyan_zydaemon_log 2>/dev/null | tail -2)
echo BOOT_CLEAN=\$(cat \$VAR/.ziyan_boot_cleanup_daemon 2>/dev/null)
SB=\$(ps -A -o pid=,rss=,args= 2>/dev/null | grep SpringBoard.app/SpringBoard | grep -v grep | head -1)
echo SB_RSS=\$SB
EOS
}
sample 166 192.168.31.166 rootful >"$OUT/m_166.log" 2>&1 &
sample 101 192.168.31.101 rootful >"$OUT/m_101.log" 2>&1 &
sample 112 192.168.31.112 rootful >"$OUT/m_112.log" 2>&1 &
sample 53 192.168.31.53 rootless >"$OUT/m_53.log" 2>&1 &
wait
echo "wrote $OUT"
for t in 166 101 112 53; do echo "==== $t ===="; grep -v Warning "$OUT/m_${t}.log" | head -20; done
