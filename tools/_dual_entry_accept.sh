#!/bin/bash
# Usage: _dual_entry_accept.sh USB|LAN
set -e
ROLE="$1"
if [ "$ROLE" = "USB" ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  SCRIPT=/private/var/mobile/Media/ZiYan/ZYCV/res/login_usb.lua
  ROUND=$VAR/.ziyan_login_usb_round.txt
  APP=/var/jb/Applications/ZiYan.app
  [ -d "$APP" ] || APP=/Applications/ZiYan.app
else
  VAR=/usr/lib/ziyan/var
  SCRIPT=/private/var/mobile/Media/ZiYan/ZYCV/res/login_lan.lua
  ROUND=$VAR/.ziyan_login_lan_round.txt
  APP=/Applications/ZiYan.app
fi

killall -9 ZiYan lua5.3 2>/dev/null || true
rm -f "$ROUND" "$VAR/.ziyan_minimize_log" "$VAR/.ziyan_app_run_trig" \
  "$VAR/.ziyan_menu_run_trig" "$VAR/.ziyan_go_home" "$VAR/.ziyan_lua_run.pid" \
  "$VAR/.ziyan_te_running" "$VAR/.ziyan_stop" "$VAR/.ziyan_paused" "$VAR/.ziyan_app_fg"

test -f "$SCRIPT" || { echo "MISSING $SCRIPT"; exit 2; }

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
touch "$VAR/.ziyan_active"
chmod 666 "$VAR/.ziyan_active" 2>/dev/null || true

pass_entry() {
  local name="$1" trig="$2"
  killall -9 lua5.3 2>/dev/null || true
  rm -f "$ROUND" "$VAR/.ziyan_lua_run.pid" "$VAR/.ziyan_minimize_log" "$VAR/.ziyan_go_home"
  echo com.ziyan.ziyan > "$VAR/.ziyan_open_app"
  sleep 3
  if ! ps -A | grep -v grep | grep -q '[Z]iYan.app/ZiYan'; then
    uiopen "$APP" >/dev/null 2>&1 || true
    sleep 3
  fi
  for i in 1 2 3 4 5 6; do
    fg=$(cat "$VAR/.ziyan_app_fg" 2>/dev/null | tr -d '[:space:]')
    [ "$fg" = "1" ] && break
    echo com.ziyan.ziyan > "$VAR/.ziyan_open_app"
    sleep 1
  done
  printf '%s\n' "$SCRIPT" > "$trig"
  chown mobile:mobile "$trig" 2>/dev/null || true
  echo "[$ROLE] TRIG_$name"
  sleep 5
  r=$(sed -n 's/.*round=\([0-9]*\).*/\1/p' "$ROUND" 2>/dev/null | head -1)
  for w in 1 2 3 4; do
    [ -n "$r" ] && [ "$r" -ge 2 ] && break
    sleep 1
    r=$(sed -n 's/.*round=\([0-9]*\).*/\1/p' "$ROUND" 2>/dev/null | head -1)
  done
  fg=$(cat "$VAR/.ziyan_app_fg" 2>/dev/null | tr -d '[:space:]')
  PID=$(cat "$VAR/.ziyan_lua_run.pid" 2>/dev/null | tr -d '[:space:]')
  alive=0
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && alive=1
  ok_min=0
  [ "$fg" = "0" ] && ok_min=1
  grep -qE 'go_home via|menu_run_ok|run_ok|background_ok' "$VAR/.ziyan_minimize_log" 2>/dev/null && ok_min=1
  ok_round=0
  [ -n "$r" ] && [ "$r" -ge 2 ] && ok_round=1
  echo "[$ROLE] $name round=$r FG=$fg PID_ALIVE=$alive OK_MIN=$ok_min OK_ROUND=$ok_round"
  tail -12 "$VAR/.ziyan_minimize_log" 2>/dev/null | sed "s/^/[$ROLE] minlog: /"
  if [ "$ok_min" = 1 ] && [ "$ok_round" = 1 ] && [ "$alive" = 1 ]; then
    echo "[$ROLE] $name=PASS"
    return 0
  fi
  echo "[$ROLE] $name=FAIL"
  return 1
}

# 1) Play ≡ app_run_trig
pass_entry PLAY "$VAR/.ziyan_app_run_trig" || PLAY_FAIL=1
# 彻底停干净再测音量「运行」路径
touch "$VAR/.ziyan_app_stop_trig" 2>/dev/null || true
killall -9 lua5.3 2>/dev/null || true
pkill -9 -f ziyan_run.lua 2>/dev/null || true
rm -f "$VAR/.ziyan_lua_run.pid" "$VAR/.ziyan_te_running" "$VAR/.ziyan_stop" "$VAR/.ziyan_paused"
sleep 2
rm -f "$VAR/.ziyan_app_stop_trig"
# 确认无残留
pkill -9 -f ziyan_run.lua 2>/dev/null || true
killall -9 lua5.3 2>/dev/null || true
sleep 1
# 重置 runState，避免仍显示 Running
cat > "$VAR/.ziyan_state.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>selectedPath</key><string>$SCRIPT</string>
<key>runState</key><integer>0</integer>
<key>runPid</key><integer>0</integer>
</dict></plist>
PLIST
sleep 1

# 2) 运行 ≡ menu_run_trig (same ZiYanRunSelected as volume menu)
pass_entry MENU "$VAR/.ziyan_menu_run_trig" || MENU_FAIL=1

# color probe
export DYLD_LIBRARY_PATH="${VAR%/var}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
LUA="${VAR%/var}/bin/lua5.3"
RUN="${VAR%/var}/lib/lua/ziyan_run.lua"
if [ "$ROLE" = "USB" ]; then
  cat > /tmp/color_p.lua <<'LUA'
function main()
  init(1)
  local sw,sh=getScreenSize()
  local c=getColor(2111,549)
  local x,y=findMultiColorInRegionFuzzy(0xb9271b,"1|0|0xb9271b,2|0|0xb9271b,3|0|0xb9271b",90,2111,549,2114,549)
  local f=io.open("/var/jb/usr/lib/ziyan/var/.ziyan_color_p.txt","w")
  f:write(string.format("size=%d,%d color=0x%06X find=%s,%s orient_ok=1\n", sw,sh,c or 0, tostring(x), tostring(y)))
  f:close()
end
LUA
else
  cat > /tmp/color_p.lua <<'LUA'
function main()
  init(1)
  local sw,sh=getScreenSize()
  local c=getColor(1045,268)
  local x,y=findMultiColorInRegionFuzzy(0x00adee,"0|1|0x00adee,0|2|0x00adee,0|3|0x00acee",90,1045,268,1045,271)
  local f=io.open("/usr/lib/ziyan/var/.ziyan_color_p.txt","w")
  f:write(string.format("size=%s,%s color=%s find=%s,%s\n", tostring(sw), tostring(sh), tostring(c), tostring(x), tostring(y)))
  f:close()
end
LUA
fi
killall -9 lua5.3 2>/dev/null || true
"$LUA" "$RUN" /tmp/color_p.lua >/dev/null 2>&1 || true
echo "[$ROLE] color: $(cat $VAR/.ziyan_color_p.txt 2>/dev/null || echo none)"
echo "[$ROLE] orient: $(tr '\n' ' ' < $VAR/.ziyan_orient 2>/dev/null)"

if [ -z "${PLAY_FAIL:-}" ] && [ -z "${MENU_FAIL:-}" ]; then
  echo "[$ROLE] ACCEPT=PASS"
else
  echo "[$ROLE] ACCEPT=FAIL"
fi
killall -9 lua5.3 2>/dev/null || true
