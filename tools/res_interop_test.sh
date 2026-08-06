#!/usr/bin/env bash
# res Lua↔Py 互通验收（真机）
set -euo pipefail
HOST="${THEOS_DEVICE_IP:-192.168.31.166}"
PASS="${ZIYAN_SSH_PASS:-alpine}"
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=12 root@"$HOST")
OUT=/usr/lib/ziyan/var/.ziyan_res_interop_test.txt

"${SSH[@]}" 'bash -s' <<REMOTE
set -e
LUA=/usr/lib/ziyan/bin/lua5.3
PY=/usr/lib/ziyan/bin/python3
RUN=/usr/lib/ziyan/lib/lua/ziyan_run.lua
RES=/private/var/mobile/Media/ZiYan/ZYCV/res
OUT=$OUT
rm -f "\$OUT"

echo "== static =="
test -f /usr/lib/ziyan/bin/ziyan_cv/ziyan_res.py
test -f /usr/lib/ziyan/bin/ziyan_cv/py_boot.py
test -f /usr/lib/ziyan/lib/lua/ziyan_res_bridge.lua
test -f /usr/lib/ziyan/lib/lua/ziyan_engine/res_interop.lua
test -f "\$RES/demo_add.py"
test -f "\$RES/demo_from_lua.lua"
test -f "\$RES/demo_from_py.py"

echo "== lua -> py =="
timeout 40 \$LUA \$RUN "\$RES/demo_from_lua.lua" || true
\$LUA - <<'EOF'
package.path="/usr/lib/ziyan/lib/lua/?.lua;/usr/lib/ziyan/lib/lua/?/init.lua;/usr/lib/ziyan/lib/lua/ziyan_engine/?.lua;/private/var/mobile/Media/ZiYan/ZYCV/res/?.lua"
dofile("/usr/lib/ziyan/lib/lua/ziyan_te_boot.lua")
dofile("/private/var/mobile/Media/ZiYan/ZYCV/res/demo_from_lua.lua")
main()
EOF
echo "--- result ---"
cat "\$OUT"
grep -q "PASS lua->py" "\$OUT"

echo "== py -> lua =="
rm -f "\$OUT"
PYTHONPATH="/usr/lib/ziyan/bin/ziyan_cv:/usr/lib/ziyan/bin:/private/var/mobile/Media/ZiYan/ZYCV/res" \
  \$PY /usr/lib/ziyan/bin/ziyan_cv/py_boot.py "\$RES/demo_from_py.py"
echo "--- result ---"
cat "\$OUT"
grep -q "PASS py->lua" "\$OUT"
echo ALL_PASS
REMOTE
