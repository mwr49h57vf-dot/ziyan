#!/usr/bin/env bash
# 真机安装 + 跑 _ziyan_smoke.lua，把结果拉回本地
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${THEOS_DEVICE_IP:-192.168.31.166}"
PASS="${ZIYAN_SSH_PASS:-alpine}"
DEB=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*.deb | head -1)
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 root@"$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

echo "== install $DEB =="
"${SCP[@]}" "$DEB" root@"$HOST":/tmp/ziyan.deb
"${SSH[@]}" 'dpkg -i /tmp/ziyan.deb; sbreload >/dev/null 2>&1 || killall -9 SpringBoard >/dev/null 2>&1 || true'
echo "wait respring..."
sleep 8

echo "== probe engine + run smoke =="
"${SSH[@]}" 'bash -s' <<'REMOTE'
set -e
OUT=/usr/lib/ziyan/var/.ziyan_smoke_result.txt
rm -f "$OUT"

# 找 API 端口
PORT=""
for p in 8000 10010 12345 8080 8888 50005 50000; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 0.3 "http://127.0.0.1:$p/api/script" 2>/dev/null || true)
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    PORT=$p
    break
  fi
done
echo "PORT=${PORT:-none}"
if [ -z "$PORT" ]; then
  # 尝试拉起引擎
  launchctl load /Library/LaunchDaemons/com.ziyan.engine.plist 2>/dev/null || true
  /usr/lib/ziyan/engine/wnriakwyww >/dev/null 2>&1 &
  sleep 2
  for p in 8000 10010 12345 8080 8888; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 0.3 "http://127.0.0.1:$p/api/script" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then PORT=$p; break; fi
  done
fi
echo "PORT2=${PORT:-none}"
[ -n "$PORT" ] || { echo "engine port not found"; ls /usr/lib/ziyan/runtime/var 2>/dev/null; cat /usr/lib/ziyan/runtime/var/config.json 2>/dev/null | head -c 400; exit 2; }

# 写启动器（与 App 同逻辑精简版）
USER=/private/var/mobile/Media/ZiYan/_ziyan_smoke.lua
DEST=/usr/lib/ziyan/runtime/scripts/_ziyan_smoke.lua
mkdir -p /usr/lib/ziyan/runtime/scripts
cat > "$DEST" <<'LAUNCH'
-- ZiYan launcher
do
  local Z = '/private/var/mobile/Media/ZiYan'
  local L = '/usr/lib/ziyan/lib/lua'
  package.path = table.concat({
    Z..'/lua/?.lua', Z..'/lua/?/init.lua',
    Z..'/ZYCV/res/?.lua', Z..'/ZYCV/res/?/init.lua',
    Z..'/?.lua', Z..'/?/init.lua',
    L..'/?.lua', L..'/?/init.lua',
    L..'/ziyan_engine/?.lua',
    '/usr/lib/ziyan/runtime/var/lib/?.lua',
  }, ';')
  package.cpath = L..'/?.so'
  pcall(dofile, L .. '/ziyan_te_boot.lua')
end
local __ZIYAN_USER_SCRIPT = '/private/var/mobile/Media/ZiYan/_ziyan_smoke.lua'
do
  local chunk, err = loadfile(__ZIYAN_USER_SCRIPT)
  if not chunk then error('无法加载: '..tostring(err), 0) end
  chunk()
end
if type(main) ~= 'function' then function main() end end
do
  local __ziyan_user_main = main
  function main()
    local ok, err = pcall(__ziyan_user_main)
    if ok then return end
    local msg = tostring(err or '')
    if msg:find('ziyan_stop', 1, true) then return end
    local cut = msg:find('stack traceback:', 1, true)
    if cut then msg = msg:sub(1, cut - 1) end
    msg = msg:gsub('/var/touchelf[^\r\n]*', '')
    msg = msg:gsub('/usr/lib/ziyan/runtime/scripts[^\r\n]*', '')
    error(msg, 0)
  end
end
LAUNCH

# 也链到 touchelf 路径
ln -sfn /usr/lib/ziyan/runtime /var/touchelf 2>/dev/null || true

curl -s -X POST --connect-timeout 3 "http://127.0.0.1:$PORT/api/script/stop" >/dev/null 2>&1 || true
sleep 0.5
echo "RUN $(curl -s -o /tmp/run_out.txt -w '%{http_code}' -X POST --connect-timeout 5 "http://127.0.0.1:$PORT/api/script/_ziyan_smoke.lua/run" || true)"
cat /tmp/run_out.txt 2>/dev/null; echo

# 等冒烟结束（最多 40s）
for i in $(seq 1 40); do
  if [ -f "$OUT" ]; then
    echo "== result =="
    cat "$OUT"
    exit 0
  fi
  sleep 1
done
echo "TIMEOUT no result"
ls -la /usr/lib/ziyan/var/ | head
ps aux | grep -i wnriak | grep -v grep || true
exit 3
REMOTE
