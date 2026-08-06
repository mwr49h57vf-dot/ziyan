#!/bin/bash
# 熔断急救：停脚本、拆 keep、禁 auto-keep（190 再现时用）
# 用法: tools/zy_miss_fuse_emergency.sh 101|112|166|53|all
set -euo pipefail
PW="${ZY_SSH_PASS:-alpine}"
target="${1:?101|112|166|53|all}"
hosts=()
if [ "$target" = "all" ]; then hosts=(101 112 166 53); else hosts=("$target"); fi

for H in "${hosts[@]}"; do
  echo "==== fuse .$H ===="
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 "root@192.168.31.$H" 'bash -s' <<'R'
V=/usr/lib/ziyan/var
[ -d /var/jb/usr/lib/ziyan/var ] && V=/var/jb/usr/lib/ziyan/var
echo 1 > "$V/.ziyan_no_auto_keep"
chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
killall -9 lua5.3 lua 2>/dev/null || true
rm -f "$V/.ziyan_active" "$V/.ziyan_script_session" "$V/.ziyan_te_running" \
      "$V/.ziyan_lua_run.pid" "$V/.ziyan_keep_daemon" "$V/.ziyan_session_keep" \
      "$V/.ziyan_color_req" "$V/.ziyan_force_recap" "$V/.ziyan_embed_alive" \
      "$V/.ziyan_embed_go" "$V/.ziyan_lua_embedded"
printf 'keepScreen\n0\nfuse\n' > "$V/.ziyan_color_req.tmp" 2>/dev/null || true
mv -f "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req" 2>/dev/null || true
echo 1 > "$V/.ziyan_release_screen" 2>/dev/null || true
echo ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0) KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
R
done
