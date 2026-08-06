#!/bin/bash
# ziyan_httpctl_serve.sh — F4 本机状态面（默认无 nc，避免 Abort trap）
# 写 .ziyan_httpctl_alive + .ziyan_httpctl_last.json；HTTP 可选 ZIYAN_HTTPCTL_NC=1
set +e
PORT=18080
if [ -d /var/jb/usr/lib/ziyan ]; then
  VAR=/var/jb/usr/lib/ziyan/var
else
  VAR=/usr/lib/ziyan/var
fi
mkdir -p "$VAR"

write_status() {
  via=$(tr -d '\n' <"$VAR/.ziyan_find_via" 2>/dev/null)
  dv=$(tr -d '\n' <"$VAR/.ziyan_daemon_v2" 2>/dev/null)
  printf '{"ok":true,"find_via":"%s","daemon_v2":"%s","port":%s}\n' \
    "$via" "$dv" "$PORT" >"$VAR/.ziyan_httpctl_last.json"
}

# 主路径：仅文件保活（gap-fx 认 alive）
while true; do
  echo 1 >"$VAR/.ziyan_httpctl_alive"
  chmod 666 "$VAR/.ziyan_httpctl_alive" 2>/dev/null || true
  write_status
  sleep 2
done
