-- Offline-only legacy action stubs. No screen, HID, app, process, or network calls.
local M = {
  name = "offline_actions",
  version = "offline-1.0.0",
  mode = "offline",
}

local VISION_REJECT = "invalid:offline_vision_args"
local VISION_UNSUPPORTED = "unsupported:offline_vision"
local TOUCH_REJECT = "invalid:offline_touch_args"
local TOUCH_UNSUPPORTED = "unsupported:offline_touch"
local APP_REJECT = "invalid:offline_app_args"
local APP_UNSUPPORTED = "unsupported:offline_app"

local function finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function color_value(value)
  if finite_number(value) then return true end
  return type(value) == "string"
    and value:match("^%s*(0[xX]%x+|%d+)%s*$") ~= nil
end

local function region(x1, y1, x2, y2)
  return finite_number(x1) and finite_number(y1)
    and finite_number(x2) and finite_number(y2)
    and x1 <= x2 and y1 <= y2
end

local function vision_result(ok)
  if not ok then return false, VISION_REJECT end
  return -1, -1, VISION_UNSUPPORTED
end

local function valid_color_region(main, sim, x1, y1, x2, y2)
  return color_value(main) and finite_number(sim)
    and sim >= 0 and sim <= 100
    and region(x1, y1, x2, y2)
end

function M.findColor(main, offset, sim, x1, y1, x2, y2)
  return vision_result(
    color_value(main) and type(offset) == "string"
      and valid_color_region(main, sim, x1, y1, x2, y2))
end

function M.findColorFuzzy(main, sim, x1, y1, x2, y2)
  return vision_result(valid_color_region(main, sim, x1, y1, x2, y2))
end

function M.findColorInRegion(main, x1, y1, x2, y2)
  return vision_result(color_value(main) and region(x1, y1, x2, y2))
end

function M.findColorInRegionFuzzy(main, sim, x1, y1, x2, y2)
  return vision_result(valid_color_region(main, sim, x1, y1, x2, y2))
end

function M.findMultiColorInRegionFuzzy(main, offset, degree, x1, y1, x2, y2)
  return vision_result(
    color_value(main) and type(offset) == "string"
      and valid_color_region(main, degree, x1, y1, x2, y2))
end

M.findMultiColor = M.findMultiColorInRegionFuzzy

local function point_args(...)
  local n = select("#", ...)
  local a, b, c
  if n == 2 then
    a, b, c = 1, ...
  elseif n == 3 then
    a, b, c = ...
  else
    return false
  end
  return finite_number(a) and a == math.floor(a) and a >= 1 and a <= 9
    and finite_number(b) and finite_number(c) and b >= 0 and c >= 0
end

local function touch_result(ok)
  if not ok then return false, TOUCH_REJECT end
  return false, TOUCH_UNSUPPORTED
end

function M.touchDown(...)
  return touch_result(point_args(...))
end

function M.touchMove(...)
  return touch_result(point_args(...))
end

local function touch_up_args(...)
  local n = select("#", ...)
  if n == 1 then
    local finger = ...
    return finite_number(finger) and finger == math.floor(finger)
      and finger >= 1 and finger <= 9
  end
  return point_args(...)
end

function M.touchUp(...)
  return touch_result(touch_up_args(...))
end

local function tap_args(...)
  local n = select("#", ...)
  local finger, x, y, hold
  if n == 2 then
    x, y = ...
    hold = nil
    finger = 1
  elseif n == 3 then
    x, y, hold = ...
    finger = 1
  elseif n == 4 then
    finger, x, y, hold = ...
  else
    return false
  end
  if not (finite_number(finger) and finger == math.floor(finger)
      and finger >= 1 and finger <= 9
      and finite_number(x) and finite_number(y) and x >= 0 and y >= 0) then
    return false
  end
  if hold ~= nil and not (finite_number(hold) and hold == math.floor(hold)
      and hold >= 0 and hold <= 60000) then
    return false
  end
  return true
end

function M.tap(...)
  return touch_result(tap_args(...))
end

local function bundle_id(value)
  return type(value) == "string"
    and value:match("^[%w][%w%._%-]*%.[%w%._%-]+$") ~= nil
end

local function app_result(bid)
  if not bundle_id(bid) then return false, APP_REJECT end
  return false, APP_UNSUPPORTED
end

function M.runApp(bid)
  return app_result(bid)
end

function M.closeApp(bid)
  return app_result(bid)
end

function M.appRunning(bid)
  return app_result(bid)
end

M.appRun = M.runApp
M.appKill = M.closeApp
M.appIsRunning = M.appRunning

M.Vision = {
  findColor = M.findColor,
  findColorFuzzy = M.findColorFuzzy,
  findColorInRegion = M.findColorInRegion,
  findColorInRegionFuzzy = M.findColorInRegionFuzzy,
  findMultiColor = M.findMultiColor,
  findMultiColorInRegionFuzzy = M.findMultiColorInRegionFuzzy,
}
M.Touch = {
  tap = M.tap,
  touchDown = M.touchDown,
  touchMove = M.touchMove,
  touchUp = M.touchUp,
}
M.App = {
  runApp = M.runApp,
  openApp = M.runApp,
  closeApp = M.closeApp,
  appRunning = M.appRunning,
  appRun = M.appRun,
  appKill = M.appKill,
  appIsRunning = M.appIsRunning,
}

function M.install(ts)
  ts.Vision = M.Vision
  ts.Touch = M.Touch
  ts.App = M.App

  _G.findColor = M.findColor
  _G.findColorFuzzy = M.findColorFuzzy
  _G.findColorInRegion = M.findColorInRegion
  _G.findColorInRegionFuzzy = M.findColorInRegionFuzzy
  _G.findMultiColor = M.findMultiColor
  _G.findMultiColorInRegionFuzzy = M.findMultiColorInRegionFuzzy
  _G.touchDown = M.touchDown
  _G.touchMove = M.touchMove
  _G.touchUp = M.touchUp
  _G.tap = M.tap
  _G.runApp = M.runApp
  _G.openApp = M.runApp
  _G.closeApp = M.closeApp
  _G.appRunning = M.appRunning
  _G.appRun = M.appRun
  _G.appKill = M.appKill
  _G.appIsRunning = M.appIsRunning
  return ts
end

return M
