--[[ Zy.Touch — 触控模块
  仅接受设计坐标 / 比例坐标；禁止固定物理像素入口。
]]
local C = require("modules._ctx")
local M = { name = "Touch", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

local function tap_logic(lx, ly, hold_ms)
  if defined("tap") then
    if hold_ms then return tap(lx, ly, hold_ms) end
    return tap(lx, ly)
  end
  if defined("touchDown") and defined("touchUp") then
    local okd = pcall(touchDown, 1, lx, ly)
    if defined("mSleep") then mSleep(hold_ms or 70) end
    local oku = pcall(touchUp, 1, lx, ly)
    return (okd and oku) or false
  end
  return false, lx, ly
end

--- 设计坐标点击（推荐）
function M.tapDesign(dx, dy, hold_ms)
  C.require_pipeline("touch")
  local Coord = require("modules.Coordinate")
  local Screen = require("modules.Screen")
  Screen.sync(C.orient, C.bid)
  local lx, ly = Coord.point(dx, dy)
  return tap_logic(lx, ly, hold_ms), lx, ly
end

--- 比例点击 0~1
function M.tapRatio(rx, ry, hold_ms)
  C.require_pipeline("touch")
  local Coord = require("modules.Coordinate")
  local Screen = require("modules.Screen")
  Screen.sync(C.orient, C.bid)
  local lx, ly = Coord.ratio(rx, ry)
  return tap_logic(lx, ly, hold_ms), lx, ly
end

--- 视觉命中点点击（逻辑点来自 Image/OCR，非手写死坐标）
function M.tapHit(lx, ly, hold_ms)
  C.require_pipeline("touch")
  lx, ly = tonumber(lx), tonumber(ly)
  if not lx or not ly or lx < 0 or ly < 0 then
    return false, "bad_hit"
  end
  local Screen = require("modules.Screen")
  Screen.sync(C.orient, C.bid)
  return tap_logic(lx, ly, hold_ms), lx, ly
end

--- 明确拒绝：物理/逻辑裸坐标（防止脚本绕过）
function M.tap(x, y, ...)
  error("Zy.Touch.tap forbidden — use tapDesign / tapRatio / tapHit (no fixed coords)", 2)
end

local function sleep(ms)
  if defined("mSleep") then mSleep(ms or 0) end
end

--- 比例滑动 0~1（推荐；禁止固定物理坐标）
function M.swipeRatio(rx1, ry1, rx2, ry2, steps, step_ms)
  C.require_pipeline("touch")
  local Coord = require("modules.Coordinate")
  local Screen = require("modules.Screen")
  Screen.sync(C.orient, C.bid)
  local x1, y1 = Coord.ratio(rx1, ry1)
  local x2, y2 = Coord.ratio(rx2, ry2)
  steps = math.max(1, tonumber(steps) or 12)
  step_ms = tonumber(step_ms) or 16
  if defined("touchDown") and defined("touchMove") and defined("touchUp") then
    pcall(touchDown, 1, x1, y1)
    for i = 1, steps do
      local t = i / steps
      local x = x1 + (x2 - x1) * t
      local y = y1 + (y2 - y1) * t
      pcall(touchMove, 1, x, y)
      sleep(step_ms)
    end
    pcall(touchUp, 1, x2, y2)
    return true, x1, y1, x2, y2
  end
  -- 兜底：两端点击（能力不足时）
  tap_logic(x1, y1, 40)
  sleep(80)
  tap_logic(x2, y2, 40)
  return true, x1, y1, x2, y2
end

--- 手势链：比例点序列 { {rx,ry}, ... }
function M.gesture(points, step_ms)
  C.require_pipeline("touch")
  points = points or {}
  if #points < 2 then return false, "need_2_points" end
  local Coord = require("modules.Coordinate")
  local Screen = require("modules.Screen")
  Screen.sync(C.orient, C.bid)
  step_ms = tonumber(step_ms) or 20
  local pts = {}
  for i, p in ipairs(points) do
    local rx = tonumber(p.rx or p[1])
    local ry = tonumber(p.ry or p[2])
    local lx, ly = Coord.ratio(rx, ry)
    pts[i] = { lx, ly }
  end
  if not (defined("touchDown") and defined("touchMove") and defined("touchUp")) then
    return false, "no_gesture_api"
  end
  pcall(touchDown, 1, pts[1][1], pts[1][2])
  for i = 2, #pts do
    pcall(touchMove, 1, pts[i][1], pts[i][2])
    sleep(step_ms)
  end
  local last = pts[#pts]
  pcall(touchUp, 1, last[1], last[2])
  return true
end

--- 设计坐标长按（hold_ms 默认 800）
function M.longPress(dx, dy, hold_ms)
  return M.tapDesign(dx, dy, tonumber(hold_ms) or 800)
end

--- 短别名：比例滑动（同 swipeRatio）
M.swipe = M.swipeRatio

--- 多指按下（finger id 1..9；设计坐标）
function M.fingerDown(id, dx, dy)
  C.require_pipeline("touch")
  local Coord = require("modules.Coordinate")
  local Screen = require("modules.Screen")
  Screen.sync(C.orient, C.bid)
  local lx, ly = Coord.point(dx, dy)
  id = math.max(1, math.min(9, tonumber(id) or 1))
  if defined("touchDown") then
    return pcall(touchDown, id, lx, ly), lx, ly
  end
  return false, lx, ly
end

function M.fingerMove(id, dx, dy)
  C.require_pipeline("touch")
  local Coord = require("modules.Coordinate")
  local lx, ly = Coord.point(dx, dy)
  id = math.max(1, math.min(9, tonumber(id) or 1))
  if defined("touchMove") then
    return pcall(touchMove, id, lx, ly), lx, ly
  end
  return false, lx, ly
end

function M.fingerUp(id, dx, dy)
  C.require_pipeline("touch")
  local Coord = require("modules.Coordinate")
  local lx, ly = Coord.point(dx, dy)
  id = math.max(1, math.min(9, tonumber(id) or 1))
  if defined("touchUp") then
    return pcall(touchUp, id, lx, ly), lx, ly
  end
  return false, lx, ly
end

--- 双指捏合（设计坐标中心 + 起止半径）
function M.pinch(cx, cy, r0, r1, steps, step_ms)
  C.require_pipeline("touch")
  steps = math.max(2, tonumber(steps) or 10)
  step_ms = tonumber(step_ms) or 20
  r0, r1 = tonumber(r0) or 80, tonumber(r1) or 20
  for i = 0, steps do
    local t = i / steps
    local r = r0 + (r1 - r0) * t
    if i == 0 then
      M.fingerDown(1, cx - r, cy)
      M.fingerDown(2, cx + r, cy)
    elseif i == steps then
      M.fingerUp(1, cx - r, cy)
      M.fingerUp(2, cx + r, cy)
    else
      M.fingerMove(1, cx - r, cy)
      M.fingerMove(2, cx + r, cy)
    end
    sleep(step_ms)
  end
  return true
end

return M
