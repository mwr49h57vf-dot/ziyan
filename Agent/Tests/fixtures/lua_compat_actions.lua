-- Minimal offline legacy-shaped fixture for vision, touch, and app lifecycle.
local ts = require("ts")
local TSLib = require("TSLib")

assert(type(ts) == "table", "require ts")
assert(type(TSLib) == "table", "require TSLib")
assert(type(ts.Vision) == "table", "ts.Vision")
assert(type(ts.Touch) == "table", "ts.Touch")
assert(type(ts.App) == "table", "ts.App")

assert(type(findColor) == "function", "global findColor")
assert(type(findMultiColorInRegionFuzzy) == "function",
  "global findMultiColorInRegionFuzzy")
assert(type(tap) == "function", "global tap")
assert(type(touchDown) == "function", "global touchDown")
assert(type(touchMove) == "function", "global touchMove")
assert(type(touchUp) == "function", "global touchUp")
assert(type(runApp) == "function", "global runApp")
assert(type(openApp) == "function", "global openApp")
assert(type(closeApp) == "function", "global closeApp")
assert(type(appRunning) == "function", "global appRunning")

local x, y, reason = findColor(
  0x123456, "0|0|0x123456", 90, 0, 0, 100, 100)
assert(x == -1 and y == -1, "valid findColor must be an offline empty result")
assert(reason == "unsupported:offline_vision", reason)

x, y, reason = findMultiColorInRegionFuzzy(
  0x123456, "0|0|0x123456", 90, 0, 0, 100, 100)
assert(x == -1 and y == -1, "valid multi-color find must be empty")
assert(reason == "unsupported:offline_vision", reason)

local ok, err = findColor(nil, "", 90, 0, 0, 100, 100)
assert(ok == false and err == "invalid:offline_vision_args", err)
ok, err = findMultiColorInRegionFuzzy(
  0x123456, "0|0|0x123456", 101, 0, 0, 100, 100)
assert(ok == false and err == "invalid:offline_vision_args", err)

ok, err = tap(100, 200, 80)
assert(ok == false and err == "unsupported:offline_touch", err)
ok, err = tap(100, 200)
assert(ok == false and err == "unsupported:offline_touch", err)
ok, err = touchDown(1, 100, 200)
assert(ok == false and err == "unsupported:offline_touch", err)
ok, err = touchMove(1, 110, 210)
assert(ok == false and err == "unsupported:offline_touch", err)
ok, err = touchUp(1, 110, 210)
assert(ok == false and err == "unsupported:offline_touch", err)
ok, err = touchUp(1)
assert(ok == false and err == "unsupported:offline_touch", err)

ok, err = tap("100", 200, 80)
assert(ok == false and err == "invalid:offline_touch_args", err)
ok, err = touchDown(10, 100, 200)
assert(ok == false and err == "invalid:offline_touch_args", err)

ok, err = runApp("com.example.game")
assert(ok == false and err == "unsupported:offline_app", err)
ok, err = openApp("com.example.game")
assert(ok == false and err == "unsupported:offline_app", err)
ok, err = closeApp("com.example.game")
assert(ok == false and err == "unsupported:offline_app", err)
local running, running_reason = appRunning("com.example.game")
assert(running == false and running_reason == "unsupported:offline_app",
  running_reason)

ok, err = runApp("")
assert(ok == false and err == "invalid:offline_app_args", err)
ok, err = openApp("com/example/game")
assert(ok == false and err == "invalid:offline_app_args", err)
ok, err = closeApp("com/example/game")
assert(ok == false and err == "invalid:offline_app_args", err)
running, running_reason = appRunning(nil)
assert(running == false and running_reason == "invalid:offline_app_args",
  running_reason)

local vx, vy, vreason = ts.Vision.findColor(
  0x123456, "0|0|0x123456", 90, 0, 0, 100, 100)
assert(vx == -1 and vy == -1 and vreason == "unsupported:offline_vision",
  vreason)
local tok, treason = ts.Touch.tap(100, 200, 80)
assert(tok == false and treason == "unsupported:offline_touch", treason)
local aok, areason = ts.App.runApp("com.example.game")
assert(aok == false and areason == "unsupported:offline_app", areason)
local ook, oreason = ts.App.openApp("com.example.game")
assert(ook == false and oreason == "unsupported:offline_app", oreason)

return true
