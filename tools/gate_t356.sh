#!/usr/bin/env bash
# ZiYan 真机门禁：T3 smoke + T5 screen + T6 touch + login_xztl load
set -u
REPORT=/usr/lib/ziyan/var/.ziyan_gate_report.txt
rm -f "$REPORT"
PASS=0
FAIL=0
BLOCK=0
log() { echo "$1" | tee -a "$REPORT"; }

LUA=/usr/lib/ziyan/bin/lua5.3
GDIR=/usr/lib/ziyan/var
mkdir -p "$GDIR"

cat > "$GDIR/.ziyan_gate_t3.lua" <<'LUA'
package.path="/usr/lib/ziyan/lib/lua/?.lua;/usr/lib/ziyan/lib/lua/?/init.lua;/usr/lib/ziyan/lib/lua/ziyan_engine/?.lua"
local ok,err=pcall(function()
  dofile("/usr/lib/ziyan/lib/lua/ziyan_te_boot.lua")
  assert(type(init)=="function")
  assert(type(mSleep)=="function")
  assert(type(toast)=="function")
  assert(type(getColor)=="function")
  assert(type(findMultiColorInRegionFuzzy)=="function")
  assert(type(tap)=="function")
  assert(type(dumpScreen)=="function")
  init(1); mSleep(50); toast("gate-t3",800)
end)
if ok then print("T3_PASS") else print("T3_FAIL", err) end
LUA

cat > "$GDIR/.ziyan_gate_t5.lua" <<'LUA'
package.path="/usr/lib/ziyan/lib/lua/?.lua;/usr/lib/ziyan/lib/lua/?/init.lua;/usr/lib/ziyan/lib/lua/ziyan_engine/?.lua"
dofile("/usr/lib/ziyan/lib/lua/ziyan_te_boot.lua")
init(1)
local p=dumpScreen("/usr/lib/ziyan/var/.ziyan_gate_shot.png")
local f=io.open(p,"rb"); local sz=f and f:seek("end") or 0; if f then f:close() end
local c=getColor(100,100)
local x,y=findMultiColorInRegionFuzzy(0xffffff,"1|0|0xffffff",50,0,0,200,200)
print("sz",sz,"c100",c,"find",x,y)
if sz and sz>100000 and c~=nil and c~=0 then print("T5_PASS") else print("T5_FAIL") end
LUA

cat > "$GDIR/.ziyan_gate_t6.lua" <<'LUA'
package.path="/usr/lib/ziyan/lib/lua/?.lua;/usr/lib/ziyan/lib/lua/?/init.lua;/usr/lib/ziyan/lib/lua/ziyan_engine/?.lua"
dofile("/usr/lib/ziyan/lib/lua/ziyan_te_boot.lua")
init(1)
local ax,ay,ac=-1,-1,-1
for y=40,600,20 do
  for x=40,1100,20 do
    local c=getColor(x,y)
    if c and c>0 then ax,ay,ac=x,y,c; break end
  end
  if ax>=0 then break end
end
print("anchor",ax,ay,ac)
if ax<0 then print("T6_FAIL no_nonzero_pixel"); return end
local r=(ac>>16)&0xff; local g=(ac>>8)&0xff; local b=ac&0xff
local hx=string.format("0x%02x%02x%02x",r,g,b)
local x1=math.max(0,ax-40); local y1=math.max(0,ay-40)
local x2=math.min(1135,ax+40); local y2=math.min(639,ay+40)
local fx,fy=findMultiColorInRegionFuzzy(ac, "1|0|"..hx, 70, x1,y1,x2,y2)
print("find",fx,fy)
if not fx or fx<0 then fx,fy=ax,ay; print("fallback_tap_anchor") end
local ok=tap(fx,fy)
print("tap_ret",ok)
mSleep(400)
print("T6_LUA_DONE",fx,fy)
LUA

log "=== T3 SMOKE ==="
OUT=$($LUA "$GDIR/.ziyan_gate_t3.lua" 2>&1)
log "$OUT"
echo "$OUT" | grep -q T3_PASS && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

log "=== T5 SCREEN ==="
OUT=$($LUA "$GDIR/.ziyan_gate_t5.lua" 2>&1)
log "$OUT"
echo "$OUT" | grep -q T5_PASS && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

log "=== T6 TOUCH ==="
: > /usr/lib/ziyan/var/.ziyan_touch_log
OUT=$($LUA "$GDIR/.ziyan_gate_t6.lua" 2>&1)
log "$OUT"
sleep 1
TL=$(tail -8 /usr/lib/ziyan/var/.ziyan_touch_log 2>/dev/null || true)
log "touch_log:"
log "$TL"

if echo "$OUT" | grep -q T6_LUA_DONE \
  && grep -q "down f=1" /usr/lib/ziyan/var/.ziyan_touch_log \
  && grep -q "up f=1" /usr/lib/ziyan/var/.ziyan_touch_log; then
  log "T6_PASS event_path"
  PASS=$((PASS+1))
  rm -f /usr/lib/ziyan/var/.ziyan_color_rep /usr/lib/ziyan/var/.ziyan_gate_after.png
  printf "dumpScreen\n/usr/lib/ziyan/var/.ziyan_gate_after.png\ngate_after\n" > /usr/lib/ziyan/var/.ziyan_color_req
  sleep 2
  SZ2=$(wc -c < /usr/lib/ziyan/var/.ziyan_gate_after.png 2>/dev/null || echo 0)
  log "after_tap_dump_sz=$SZ2"
  if [ "${SZ2:-0}" -gt 100000 ]; then
    log "T6_SCREEN_OK"
  else
    log "T6_SCREEN_DEGRADED"
    BLOCK=$((BLOCK+1))
  fi
else
  log "T6_FAIL"
  FAIL=$((FAIL+1))
fi

log "=== LOGIN SCRIPT LOAD ==="
killall -9 lua5.3 2>/dev/null || true
OUT=$(timeout 8 $LUA /usr/lib/ziyan/lib/lua/ziyan_run.lua /private/var/mobile/Media/ZiYan/login_xztl.lua 2>&1 || true)
killall -9 lua5.3 2>/dev/null || true
log "login_out_head:"
log "$(echo "$OUT" | head -8)"
if echo "$OUT" | grep -qiE "load error|runtime error|main\(\) error"; then
  log "LOGIN_FAIL"
  FAIL=$((FAIL+1))
else
  log "LOGIN_PASS truncated_loop"
  PASS=$((PASS+1))
fi

log "=== SUMMARY pass=$PASS fail=$FAIL block=$BLOCK ==="
if [ "$FAIL" -gt 0 ]; then
  echo GATE_FAIL
  exit 1
fi
if [ "$BLOCK" -gt 0 ]; then
  echo GATE_BLOCKED
  exit 2
fi
echo GATE_PASS
exit 0
