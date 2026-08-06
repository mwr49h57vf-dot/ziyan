#!/bin/bash
ROLE="$1"
if [ "$ROLE" = "USB" ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  ZROOT=/var/jb/usr/lib/ziyan
else
  VAR=/usr/lib/ziyan/var
  ZROOT=/usr/lib/ziyan
fi
CR=/private/var/var/mobile/Library/Logs/CrashReporter
[ -d /var/mobile/Library/Logs/CrashReporter ] && CR=/var/mobile/Library/Logs/CrashReporter

echo "========== [$ROLE] 1 SYSTEM =========="
sw_vers 2>/dev/null
uname -a
dpkg -l com.ziyan.ziyan 2>/dev/null | tail -5

echo "========== [$ROLE] 2 PS =========="
ps aux 2>/dev/null | grep -iE 'lua5|ZiYan|SpringBoard' | grep -v grep || ps -A 2>/dev/null | grep -iE 'lua5|ZiYan|SpringBoard' | grep -v grep

echo "========== [$ROLE] 3 VAR STATE =========="
for f in .ziyan_orient .ziyan_sb_alive .ziyan_screen_info; do
  echo "--- $f ---"
  cat "$VAR/$f" 2>/dev/null || echo MISSING
done
echo "--- .ziyan_touch_log tail ---"
tail -20 "$VAR/.ziyan_touch_log" 2>/dev/null || echo MISSING
echo "--- ls -lt VAR ---"
ls -lt "$VAR" 2>/dev/null | head -20

echo "========== [$ROLE] 4 SCRIPTS =========="
echo -n "lua_run.pid: "; cat "$VAR/.ziyan_lua_run.pid" 2>/dev/null; echo
echo "--- state.plist ---"
cat "$VAR/.ziyan_state.plist" 2>/dev/null || cat /var/mobile/Media/ZiYan/selected.plist 2>/dev/null || echo MISSING
ls -la /var/mobile/Media/ZiYan/ 2>/dev/null | head -12
echo "--- login*.lua head ---"
head -5 /var/mobile/Media/ZiYan/login*.lua 2>/dev/null
echo "--- find lines in login*.lua ---"
grep -n find /var/mobile/Media/ZiYan/login*.lua 2>/dev/null | head -25

echo "========== [$ROLE] 5 LIVE init(1) PROBE =========="
export DYLD_LIBRARY_PATH="$ZROOT/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
LUA="$ZROOT/bin/lua5.3"
RUN="$ZROOT/lib/lua/ziyan_run.lua"
PROBE="/tmp/_ziyan_diag_probe.lua"
cat > "$PROBE" << 'LUAEOF'
function main()
  local VAR = rawget(_G, "ZIYAN_VAR") or "/usr/lib/ziyan/var"
  local OUT = VAR .. "/.ziyan_diag_probe.txt"
  local lines = {}
  local function L(s) lines[#lines+1] = s end
  init(1)
  mSleep(200)
  local sw, sh = getScreenSize()
  L(string.format("init1 size=%s,%s", tostring(sw), tostring(sh)))
  if type(keepScreen) == "function" then
    pcall(keepScreen, true)
    L("keepScreen(true) ok")
  else
    L("keepScreen MISSING")
  end
  local cx = math.floor((tonumber(sw) or 1136) / 2)
  local cy = math.floor((tonumber(sh) or 640) / 2)
  local c0 = -1
  if type(getColor) == "function" then
    local ok, c = pcall(getColor, cx, cy)
    c0 = ok and (tonumber(c) or -1) or -1
    L(string.format("getColor center @%d,%d = 0x%06X ok=%s", cx, cy, c0 >= 0 and c0 or 0, tostring(ok)))
  end
  local fx, fy = -1, -1
  if type(findMultiColorInRegionFuzzy) == "function" and c0 >= 0 then
    local off = string.format("1|0|0x%06x,2|0|0x%06x,3|0|0x%06x", c0, c0, c0)
    fx, fy = findMultiColorInRegionFuzzy(c0, off, 85, math.max(0, cx-4), cy, math.min((tonumber(sw) or 1136)-1, cx+4), cy)
    L(string.format("findMulti center-color h4 = %s,%s", tostring(fx), tostring(fy)))
    if fx and fx ~= -1 then L("FIND=PASS") else L("FIND=FAIL") end
  else
    L("findMulti SKIP c0=" .. tostring(c0))
    L("FIND=FAIL")
  end
  if type(keepScreen) == "function" then pcall(keepScreen, false) end
  pcall(function() os.execute(": > " .. VAR .. "/.ziyan_touch_log 2>/dev/null") end)
  local tf = io.open(VAR .. "/.ziyan_touch_log", "w"); if tf then tf:close() end
  local touch_rep = ""
  if type(tap) == "function" then
    pcall(tap, cx, cy)
    mSleep(450)
    L(string.format("tap center %d,%d", cx, cy))
    local f = io.open(VAR .. "/.ziyan_touch_rep", "r")
    if f then touch_rep = f:read("*a") or ""; f:close() end
    L("touch_rep=" .. touch_rep:gsub("\n", " | "))
    local tl = io.open(VAR .. "/.ziyan_touch_log", "r")
    if tl then
      local all = tl:read("*a") or ""
      tl:close()
      local tail = all:match("(([^\n]*\n){0,12})$") or all
      L("touch_log_tail:\n" .. tail)
    end
    local hid = touch_rep:find("hid") or touch_rep:find("IOHID")
    local win = touch_rep:find("win") or touch_rep:find("window")
    local orient = touch_rep:find("orient") or (io.open(VAR .. "/.ziyan_orient", "r") and "orient_file")
    if touch_rep ~= "" and #touch_rep > 2 then L("TAP=PASS") else L("TAP=FAIL") end
  else
    L("tap MISSING"); L("TAP=FAIL")
  end
  local f = io.open(OUT, "w")
  if f then f:write(table.concat(lines, "\n")); f:write("\n"); f:close() end
end
LUAEOF
killall -9 lua5.3 2>/dev/null || true
sleep 0.5
if [ -x "$LUA" ] && [ -f "$RUN" ]; then
  "$LUA" "$RUN" "$PROBE" 2>&1 | tail -5
  sleep 1
  cat "$VAR/.ziyan_diag_probe.txt" 2>/dev/null || echo PROBE_OUTPUT_MISSING
else
  echo "LUA/RUN missing: $LUA $RUN"
fi

echo "========== [$ROLE] 6 CRASHES =========="
for dir in "$CR" /Library/Logs/CrashReporter; do
  [ -d "$dir" ] || continue
  echo "--- SpringBoard in $dir ---"
  ls -lt "$dir"/SpringBoard* 2>/dev/null | head -3
  echo "--- Jetsam in $dir ---"
  ls -lt "$dir"/JetsamEvent* 2>/dev/null | head -3
done

if [ "$ROLE" = "USB" ]; then
  echo "========== [$ROLE] 7 USB EXTRAS =========="
  echo "--- memory (vm_stat head / physmem) ---"
  vm_stat 2>/dev/null | head -8
  sysctl hw.memsize 2>/dev/null
  echo "--- .ziyan_ocr count in VAR ---"
  ls -lt "$VAR"/.ziyan_ocr* 2>/dev/null | head -10 || echo none
  echo "--- color_req ---"
  ls -lt "$VAR"/.ziyan_color_req* "$VAR"/color_req* 2>/dev/null | head -5
  cat "$VAR/.ziyan_color_req" 2>/dev/null | head -5
  fuser "$VAR/.ziyan_color_req" 2>/dev/null || true
  ps aux 2>/dev/null | grep -i ziyan_ocr | grep -v grep || true
fi
