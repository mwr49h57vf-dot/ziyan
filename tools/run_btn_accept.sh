#!/usr/bin/env bash
# ZiYan App「运行」按钮自动验收（T0–T5）
# 触发：.ziyan_open_app 打开 App → .ziyan_app_run_trig（≡ runButtonTapped + minimize）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=zy_guard_no_auto_respring.sh
. "$ROOT/tools/zy_guard_no_auto_respring.sh"
zy_guard_block_unless_manual "$@"
HOST="${THEOS_DEVICE_IP:-192.168.31.166}"
PASS="${ZIYAN_SSH_PASS:-alpine}"
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=15 root@"$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=15)

SCRIPT="/private/var/mobile/Media/ZiYan/_ziyan_run_btn_test.lua"
VAR=/usr/lib/ziyan/var
STAMP=$(date +%Y%m%d_%H%M%S)
REPORT_LOCAL="$ROOT/api_spec/device_reports/run_btn_accept_${STAMP}.md"
mkdir -p "$(dirname "$REPORT_LOCAL")"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

SKIP_BUILD="${SKIP_BUILD:-0}"
if [ "$SKIP_BUILD" != "1" ]; then
  echo "== T0 make package =="
  cd "$ROOT"
  make package
fi
DEB=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*.deb | head -1)
echo "DEB=$DEB"

echo "== T0 install + ldrestart =="
"${SCP[@]}" "$DEB" root@"$HOST":/tmp/ziyan_run_btn.deb
"${SCP[@]}" "$ROOT/layout/private/var/mobile/Media/ZiYan/_ziyan_run_btn_test.lua" \
  root@"$HOST":/tmp/_ziyan_run_btn_test.lua

"${SSH[@]}" bash -s <<REMOTE
set -e
dpkg -i /tmp/ziyan_run_btn.deb
cp -f /tmp/_ziyan_run_btn_test.lua "$SCRIPT"
chown mobile:mobile "$SCRIPT"
mkdir -p /private/var/mobile/Media/ZiYan $VAR
cat > $VAR/.ziyan_state.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>selectedPath</key><string>$SCRIPT</string>
<key>runState</key><integer>0</integer>
<key>runPid</key><integer>0</integer>
</dict></plist>
PLIST
cp -f $VAR/.ziyan_state.plist /private/var/mobile/Media/ZiYan/.ziyan_state.plist
uicache -p /Applications/ZiYan.app >/dev/null 2>&1 || true
if [ "${ZY_ALLOW_MANUAL_RESPRING:-0}" = 1 ]; then
  ldrestart
else
  echo BLOCKED_AUTO_SB_RESTART
  exit 78
fi
REMOTE
echo "wait ldrestart..."
sleep 22

echo "== T1–T5 =="
RESULT=$("${SSH[@]}" bash -s <<REMOTE
set +e
VAR=$VAR
SCRIPT=$SCRIPT
killall -9 ZiYan lua5.3 2>/dev/null
rm -f \$VAR/.ziyan_run_btn_test.txt \$VAR/.ziyan_lua_run.pid \$VAR/.ziyan_minimize_log \
  \$VAR/.ziyan_app_run_trig \$VAR/.ziyan_go_home \$VAR/.ziyan_app_fg \
  \$VAR/.ziyan_te_running \$VAR/.ziyan_stop \$VAR/.ziyan_paused

# T1 open via SpringBoard IPC
echo com.ziyan.ziyan > \$VAR/.ziyan_open_app
sleep 4
if ! ps -A | grep -v grep | grep -q '[Z]iYan.app/ZiYan'; then
  uiopen /Applications/ZiYan.app >/dev/null 2>&1
  sleep 3
fi
ps -A | grep -v grep | grep '[Z]iYan.app/ZiYan' || { echo APP_MISSING; exit 3; }
for i in 1 2 3 4 5 6 7 8 9 10; do
  fg=\$(cat \$VAR/.ziyan_app_fg 2>/dev/null | tr -d '[:space:]')
  echo fg=\$fg
  [ "\$fg" = "1" ] && break
  echo com.ziyan.ziyan > \$VAR/.ziyan_open_app
  sleep 1
done

# T3 trigger = Play
printf '%s\n' "\$SCRIPT" > \$VAR/.ziyan_app_run_trig
chown mobile:mobile \$VAR/.ziyan_app_run_trig
echo TRIG_WRITTEN
sleep 6

echo '--- minimize_log ---'
cat \$VAR/.ziyan_minimize_log 2>/dev/null || echo '(none)'
echo '--- app_fg ---'
cat \$VAR/.ziyan_app_fg 2>/dev/null || echo '(none)'
echo '--- round ---'
cat \$VAR/.ziyan_run_btn_test.txt 2>/dev/null || echo '(none)'
PID=\$(cat \$VAR/.ziyan_lua_run.pid 2>/dev/null | tr -d '[:space:]')
echo PID=\$PID
if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then echo PID_ALIVE=1; else echo PID_ALIVE=0; fi

ok_round=0
r=\$(sed -n 's/.*round=\([0-9]*\).*/\1/p' \$VAR/.ziyan_run_btn_test.txt 2>/dev/null | head -1)
[ -n "\$r" ] && [ "\$r" -ge 2 ] && ok_round=1
echo round=\$r OK_ROUND=\$ok_round

fg=\$(cat \$VAR/.ziyan_app_fg 2>/dev/null | tr -d '[:space:]')
ok_min=0
[ "\$fg" = "0" ] && ok_min=1
grep -q 'sb go_home via' \$VAR/.ziyan_minimize_log 2>/dev/null && ok_min=1
grep -q 'path=background_ok' \$VAR/.ziyan_minimize_log 2>/dev/null && ok_min=1
echo FG=\$fg OK_MIN=\$ok_min

if [ "\$ok_round" = 1 ] && [ "\$ok_min" = 1 ] && kill -0 "\$PID" 2>/dev/null; then
  echo ACCEPT=PASS
else
  echo ACCEPT=FAIL
fi

# T5 stop
touch \$VAR/.ziyan_app_stop_trig
sleep 2
killall -9 lua5.3 2>/dev/null
rm -f \$VAR/.ziyan_lua_run.pid \$VAR/.ziyan_app_stop_trig \$VAR/.ziyan_te_running
if ps -A | grep -v grep | grep -q ziyan_run; then echo STOP=FAIL; else echo STOP=PASS; fi
REMOTE
)

echo "$RESULT"
if ! echo "$RESULT" | grep -q 'ACCEPT=PASS'; then
  {
    echo "# Run button accept FAIL"
    echo "- Device: $HOST"
    echo "- Package: $(basename "$DEB")"
    echo
    echo '```'
    echo "$RESULT"
    echo '```'
  } > "$REPORT_LOCAL"
  fail "see $REPORT_LOCAL"
fi

{
  echo "# Run button accept PASS"
  echo
  echo "- Device: $HOST"
  echo "- Package: $(basename "$DEB")"
  echo "- Script: $SCRIPT"
  echo "- Trigger: \`.ziyan_app_run_trig\` ≡ \`runButtonTapped\` + minimize"
  echo
  echo '```'
  echo "$RESULT"
  echo '```'
  echo
  echo "## Manual steps"
  echo "1. 打开 ZiYan"
  echo "2. 勾选 \`_ziyan_run_btn_test.lua\`（或任意 .lua）"
  echo "3. 点导航栏 Play"
  echo "4. 应 toast「已启动」后回桌面，脚本继续跑"
  echo "5. 再打开 App 点 Play 应停止"
} > "$REPORT_LOCAL"

pass "report $REPORT_LOCAL"
echo "YOU_CAN_MANUAL_TEST=1"
