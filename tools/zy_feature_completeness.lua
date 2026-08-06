-- tools/zy_feature_completeness.lua — 子砚全功能完整性冒烟（自研，非触动）
-- 循环阻塞隐患：Desktop 脚本占用找色时跳过屏幕热路径，避免 90s 挂死
function main()
local VAR = _G.ZIYAN_VAR
  or ((io.open("/var/jb/usr/lib/ziyan/var", "r") and "/var/jb/usr/lib/ziyan/var") or "/usr/lib/ziyan/var")
local LUALIB = _G.ZIYAN_LUA
  or ((io.open("/var/jb/usr/lib/ziyan/lib/lua/modules/init.lua", "r")
    and "/var/jb/usr/lib/ziyan/lib/lua") or "/usr/lib/ziyan/lib/lua")
package.path = LUALIB .. "/?.lua;" .. LUALIB .. "/modules/?.lua;" .. package.path

local pass_n, fail_n, skip_n = 0, 0, 0
local lines = {}
local function flush_progress(tag)
  local f = io.open(VAR .. "/.ziyan_feature_completeness", "w")
  if f then
    f:write(string.format("pass=%d fail=%d skip=%d progress=%s\n", pass_n, fail_n, skip_n, tostring(tag or "")))
    for _, L in ipairs(lines) do f:write(L .. "\n") end
    f:close()
  end
  io.stdout:write(string.format("PROGRESS %s pass=%d fail=%d\n", tostring(tag), pass_n, fail_n))
  io.stdout:flush()
end
local function rec(mod, name, st, detail)
  lines[#lines + 1] = string.format("%s|%s.%s|%s", st, mod, name, tostring(detail or ""))
  if st == "PASS" then pass_n = pass_n + 1
  elseif st == "SKIP" then skip_n = skip_n + 1
  else fail_n = fail_n + 1 end
end
local function try(mod, name, fn)
  local ok, err = pcall(fn)
  if ok then rec(mod, name, "PASS", "ok") else rec(mod, name, "FAIL", err) end
end
local function need(mod, name, fn)
  if type(fn) ~= "function" then rec(mod, name, "FAIL", "missing") else rec(mod, name, "PASS", "exists") end
end

flush_progress("start")

local Zy = _G.Zy
if type(Zy) ~= "table" then
  local ok, mod = pcall(dofile, LUALIB .. "/modules/init.lua")
  if ok and type(mod) == "table" then Zy = mod; _G.Zy = mod
  else Zy = {}; rec("Zy", "init", "FAIL", tostring(mod)) end
end

local mods = {
  "Device","App","Screen","Coordinate","Image","OCR","Touch","File","Network",
  "Verify","StateMachine","Game","Diagnose","Case","Engine","Script","AI",
  "Config","Input","UI","Knowledge","Optimization","Log","Thread","Widget",
  "HttpCtl","PerfGate","HealthMonitor","SafeExecutor","Util",
  "AppDump","AntiDetect","Sandbox","FrameHook","AutoInject",
}

for _, n in ipairs(mods) do
  local m = Zy[n]
  if type(m) ~= "table" or m.error then
    local ok, mod = pcall(require, n)
    if not ok then ok, mod = pcall(dofile, LUALIB .. "/modules/" .. n .. ".lua") end
    if ok and type(mod) == "table" then m = mod; Zy[n] = mod end
  end
  if type(m) == "table" and not m.error then
    rec("load", n, "PASS", "ok")
  else
    rec("load", n, "FAIL", (m and m.error) or "absent")
  end
end
flush_progress("mods")

local busy = io.open(VAR .. "/.ziyan_script_session", "r") or io.open(VAR .. "/.ziyan_color_req", "r")
if busy then busy:close() end

try("Global", "init", function() init(1) end)
try("Global", "mSleep", function() mSleep(30) end)

if busy then
  rec("Global", "getColor", "SKIP", "script_busy")
  rec("Global", "keepScreen", "SKIP", "script_busy")
  rec("Global", "findMultiColorInRegionFuzzy", "SKIP", "script_busy")
  rec("Global", "tap", "SKIP", "script_busy")
else
  try("Global", "getColor", function() assert(type(getColor(10, 10)) == "number") end)
  try("Global", "keepScreen", function() keepScreen(true); keepScreen(false) end)
  try("Global", "findMultiColorInRegionFuzzy", function()
    keepScreen(true)
    local c = getColor(20, 20); if type(c) ~= "number" then c = 0xffffff end
    local x = findMultiColorInRegionFuzzy(c, string.format("0|0|0x%06x", c % 0x1000000), 85, 10, 10, 80, 80)
    keepScreen(false); assert(type(x) == "number")
  end)
  try("Global", "tap", function() tap(40, 40) end)
end

if type(Zy.Screen) == "table" then
  need("Screen", "size", Zy.Screen.size)
  need("Screen", "info", Zy.Screen.info)
end
if type(Zy.Image) == "table" then need("Image", "findColor", Zy.Image.findColor) end
if type(Zy.Touch) == "table" then need("Touch", "tap", Zy.Touch.tap or Zy.Touch.click) end
if type(Zy.HttpCtl) == "table" then need("HttpCtl", "status", Zy.HttpCtl.status) end
if type(Zy.PerfGate) == "table" then
  try("PerfGate", "export", function()
    if type(Zy.PerfGate.export) == "function" then Zy.PerfGate.export() end
  end)
end
if type(Zy.Thread) == "table" then need("Thread", "create", Zy.Thread.create or Zy.Thread.start) end
if type(Zy.AppDump) == "table" then need("AppDump", "status", Zy.AppDump.status) end
if type(Zy.AntiDetect) == "table" then need("AntiDetect", "probe", Zy.AntiDetect.probe) end
if type(Zy.Sandbox) == "table" then need("Sandbox", "run", Zy.Sandbox.run) end
if type(Zy.FrameHook) == "table" then need("FrameHook", "status", Zy.FrameHook.status) end
if type(Zy.AutoInject) == "table" then need("AutoInject", "status", Zy.AutoInject.status) end
need("OCR", "region", Zy.OCR and Zy.OCR.region)
need("Vision", "findColor", Zy.Vision and Zy.Vision.findColor)

local out = VAR .. "/.ziyan_feature_completeness"
local f = io.open(out, "w")
if f then
  f:write(string.format("pass=%d fail=%d skip=%d\n", pass_n, fail_n, skip_n))
  for _, L in ipairs(lines) do f:write(L .. "\n") end
  f:close()
end
print(string.format("FEATURES pass=%d fail=%d skip=%d", pass_n, fail_n, skip_n))
if fail_n == 0 then print("FEATURES_PASS") else print("FEATURES_FAIL") end
io.stdout:flush()
end
