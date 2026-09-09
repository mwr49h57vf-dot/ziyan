local execute_calls = 0
local popen_calls = 0
local original_execute = os.execute
local original_popen = io.popen

os.execute = function()
  execute_calls = execute_calls + 1
  error("os.execute forbidden")
end
io.popen = function()
  popen_calls = popen_calls + 1
  error("io.popen forbidden")
end

local TSLib = assert(require("TSLib"))
local ts = assert(TSLib.ts)
assert(type(ts.Vision) == "table")
assert(type(ts.Touch) == "table")
assert(type(ts.App) == "table")

assert(type(findColor) == "function")
assert(type(findMultiColorInRegionFuzzy) == "function")
assert(type(tap) == "function")
assert(type(touchDown) == "function")
assert(type(touchMove) == "function")
assert(type(touchUp) == "function")
assert(type(runApp) == "function")
assert(type(closeApp) == "function")
assert(type(appRunning) == "function")

local x, y, reason = ts.Vision.findColor(
  0x123456, "0|0|0x123456", 90, 0, 0, 100, 100)
assert(x == -1 and y == -1 and reason == "unsupported:offline_vision", reason)

local ok, err = ts.Touch.tap(100, 200, 80)
assert(ok == false and err == "unsupported:offline_touch", err)

ok, err = ts.App.runApp("com.example.game")
assert(ok == false and err == "unsupported:offline_app", err)

ok, err = ts.Vision.findColor(nil, "", 90, 0, 0, 100, 100)
assert(ok == false and err == "invalid:offline_vision_args", err)

ok, err = ts.Touch.tap("100", 200, 80)
assert(ok == false and err == "invalid:offline_touch_args", err)

ok, err = ts.App.runApp("")
assert(ok == false and err == "invalid:offline_app_args", err)

local gx, gy, greason = findMultiColorInRegionFuzzy(
  0x123456, "0|0|0x123456", 90, 0, 0, 100, 100)
assert(gx == -1 and gy == -1 and greason == "unsupported:offline_vision",
  greason)

local g_ok, g_reason = tap(100, 200)
assert(g_ok == false and g_reason == "unsupported:offline_touch", g_reason)

local a_ok, a_reason = runApp("com.example.game")
assert(a_ok == false and a_reason == "unsupported:offline_app", a_reason)

os.execute = original_execute
io.popen = original_popen
assert(execute_calls == 0, "os.execute called")
assert(popen_calls == 0, "io.popen called")

print("LUA_RESULT=PASS")
print("STUB_RESULTS=vision:unsupported:offline_vision,touch:unsupported:offline_touch,app:unsupported:offline_app")
print("INVALID_RESULTS=vision:invalid:offline_vision_args,touch:invalid:offline_touch_args,app:invalid:offline_app_args")
print("SIDE_EFFECT_CALLS=os.execute:0,io.popen:0")
