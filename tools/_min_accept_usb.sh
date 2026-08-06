#!/bin/bash
# USB: App 运行 → minimize + login_usb ≥2 rounds
set -e
VAR=/var/jb/usr/lib/ziyan/var
SCRIPT=/private/var/mobile/Media/ZiYan/ZYCV/res/login_usb.lua
killall -9 ZiYan lua5.3 2>/dev/null || true
rm -f "$VAR/.ziyan_login_usb_round.txt" "$VAR/.ziyan_minimize_log" \
  "$VAR/.ziyan_app_run_trig" "$VAR/.ziyan_go_home" "$VAR/.ziyan_lua_run.pid" \
  "$VAR/.ziyan_te_running" "$VAR/.ziyan_stop" "$VAR/.ziyan_paused" \
  "$VAR/.ziyan_app_fg"

# ensure script
test -f "$SCRIPT" || { echo "MISSING $SCRIPT"; exit 2; }
head -5 "$SCRIPT"

# select + open App
cat > "$VAR/.ziyan_state.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>selectedPath</key><string>$SCRIPT</string>
<key>runState</key><integer>0</integer>
<key>runPid</key><integer>0</integer>
</dict></plist>
PLIST
chown mobile:mobile "$VAR/.ziyan_state.plist" "$SCRIPT" 2>/dev/null || true

echo com.ziyan.ziyan > "$VAR/.ziyan_open_app"
sleep 4
if ! ps -A | grep -v grep | grep -q '[Z]iYan.app/ZiYan'; then
  uiopen "$([ -d /var/jb/Applications/ZiYan.app ] && echo /var/jb/Applications/ZiYan.app || echo /Applications/ZiYan.app)" >/dev/null 2>&1 || true
  sleep 3
fi
for i in 1 2 3 4 5 6 7 8; do
  fg=$(cat "$VAR/.ziyan_app_fg" 2>/dev/null | tr -d '[:space:]')
  echo "fg=$fg"
  [ "$fg" = "1" ] && break
  echo com.ziyan.ziyan > "$VAR/.ziyan_open_app"
  sleep 1
done

T0=$(date +%s)
printf '%s\n' "$SCRIPT" > "$VAR/.ziyan_app_run_trig"
chown mobile:mobile "$VAR/.ziyan_app_run_trig"
echo TRIG_WRITTEN t0=$T0
sleep 5
T1=$(date +%s)

echo '--- minimize_log ---'
cat "$VAR/.ziyan_minimize_log" 2>/dev/null || echo '(none)'
echo '--- app_fg ---'
cat "$VAR/.ziyan_app_fg" 2>/dev/null || echo '(none)'
echo '--- round ---'
cat "$VAR/.ziyan_login_usb_round.txt" 2>/dev/null || echo '(none)'
echo '--- orient ---'
cat "$VAR/.ziyan_orient" 2>/dev/null || echo '(none)'
PID=$(cat "$VAR/.ziyan_lua_run.pid" 2>/dev/null | tr -d '[:space:]')
echo PID=$PID
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then echo PID_ALIVE=1; else echo PID_ALIVE=0; fi

# wait extra for round>=2
for w in 1 2 3 4 5 6; do
  r=$(sed -n 's/.*round=\([0-9]*\).*/\1/p' "$VAR/.ziyan_login_usb_round.txt" 2>/dev/null | head -1)
  [ -n "$r" ] && [ "$r" -ge 2 ] && break
  sleep 1
done
r=$(sed -n 's/.*round=\([0-9]*\).*/\1/p' "$VAR/.ziyan_login_usb_round.txt" 2>/dev/null | head -1)
echo round=$r DT=$((T1-T0))

ok_round=0
[ -n "$r" ] && [ "$r" -ge 2 ] && ok_round=1
ok_min=0
fg=$(cat "$VAR/.ziyan_app_fg" 2>/dev/null | tr -d '[:space:]')
[ "$fg" = "0" ] && ok_min=1
grep -q 'sb go_home via' "$VAR/.ziyan_minimize_log" 2>/dev/null && ok_min=1
grep -q 'path=background_ok' "$VAR/.ziyan_minimize_log" 2>/dev/null && ok_min=1
grep -q 'run_ok' "$VAR/.ziyan_minimize_log" 2>/dev/null && ok_run=1 || ok_run=0
echo FG=$fg OK_MIN=$ok_min OK_ROUND=$ok_round OK_RUN=$ok_run

if [ "$ok_run" = 1 ] && [ "$ok_min" = 1 ] && [ "$ok_round" = 1 ] && kill -0 "$PID" 2>/dev/null; then
  echo ACCEPT=PASS
else
  echo ACCEPT=FAIL
fi
