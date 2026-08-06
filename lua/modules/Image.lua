--[[ Zy.Image — 图像/找色模块（经 Coordinate）
  找色架构与子砚抓色器一致：
    x, y = findMultiColorInRegionFuzzy(0x主色, "dx|dy|0x..,...", degree, x1, y1, x2, y2)
  偏点串：相对首点；degree 常 90；ROI 为 A→S。
]]
local C = require("modules._ctx")
local M = { name = "Image", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

--- 与抓色器生成函数同名同参（逻辑/设计区经 Coordinate）
function M.findMultiColorInRegionFuzzy(main, offset, degree, x1, y1, x2, y2)
  C.require_pipeline("vision")
  local dw, dh = C.require_design()
  local Coord = require("modules.Coordinate")
  local a, b, c, d = Coord.region(x1 or 0, y1 or 0, x2 or dw, y2 or dh)
  if defined("findMultiColorInRegionFuzzy") then
    local fx, fy = findMultiColorInRegionFuzzy(
      main, offset or "", tonumber(degree) or 90, a, b, c, d)
    return tonumber(fx) or -1, tonumber(fy) or -1
  end
  return -1, -1
end

--- 抓色器别名：参数同 findMultiColorInRegionFuzzy
function M.findMultiColor(main, offset, degree, x1, y1, x2, y2)
  return M.findMultiColorInRegionFuzzy(main, offset, degree, x1, y1, x2, y2)
end

--- 设计区域找色（同抓色器 7 参；旧名保留）
function M.findColor(main, offset, sim, x1, y1, x2, y2)
  C.require_pipeline("vision")
  local dw, dh = C.require_design()
  if defined("visionFindColor") then
    return visionFindColor(main, offset, sim, x1, y1, x2, y2, dw, dh)
  end
  return M.findMultiColorInRegionFuzzy(main, offset, sim, x1, y1, x2, y2)
end

--- 设计区域找图（经 vision_gate → daemon 当前帧）
function M.find(path, fuzzy, x1, y1, x2, y2)
  C.require_pipeline("vision")
  pcall(function()
    local cv = package.loaded["ziyan_engine.cv"]
    if type(cv) == "table" and type(cv.vision_gate) == "function" then
      cv.vision_gate("findImage")
    elseif type(cv) == "table" and type(cv.ensure_foreground_frame) == "function" then
      cv.ensure_foreground_frame()
    end
  end)
  local Coord = require("modules.Coordinate")
  local a, b, c, d
  if x1 and y1 and x2 and y2 then
    a, b, c, d = Coord.region(x1, y1, x2, y2)
  else
    local Screen = require("modules.Screen")
    local w, h = Screen.size()
    a, b, c, d = 0, 0, w - 1, h - 1
  end
  if defined("findImageInRegionFuzzy") then
    return findImageInRegionFuzzy(path, tonumber(fuzzy) or 0.9, a, b, c, d)
  end
  if defined("findImage") then
    return findImage(path, fuzzy)
  end
  return -1, -1
end

--- 逻辑点取色（须已 sync；点须来自 Coordinate）
function M.colorAtLogic(lx, ly)
  C.require_pipeline("vision")
  if defined("getColor") then return tonumber(getColor(lx, ly)) or 0 end
  return 0
end

function M.colorAtDesign(dx, dy)
  local Coord = require("modules.Coordinate")
  local lx, ly = Coord.point(dx, dy)
  return M.colorAtLogic(lx, ly), lx, ly
end

--- 超时内轮询找色（Until 思想；设计区域）
function M.findUntil(main, offset, sim, x1, y1, x2, y2, timeout_ms, interval_ms)
  timeout_ms = tonumber(timeout_ms) or 5000
  interval_ms = tonumber(interval_ms) or 400
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < timeout_ms do
    local fx, fy = M.findColor(main, offset, sim, x1, y1, x2, y2)
    if fx and fx ~= -1 then return true, fx, fy end
    if defined("mSleep") then mSleep(interval_ms) end
  end
  return false, -1, -1
end

-- ========== 功能设计 P0：命名 matcher（Ai代码训练兼容）==========
local _matchers = {}

--- 注册找色/找图 matcher
-- spec = { type="color"|"image", main=, offset=, sim=, path=, region={x1,y1,x2,y2} }
function M.registerMatcher(name, spec)
  if type(name) ~= "string" or name == "" or type(spec) ~= "table" then
    return false, "bad_args"
  end
  _matchers[name] = spec
  return true
end

function M.match(name)
  local sp = _matchers[name]
  if not sp then return false, -1, -1, "no_matcher" end
  local r = sp.region or {}
  if (sp.type or "color") == "image" then
    local x, y = M.find(sp.path, sp.sim or sp.fuzzy, r[1] or r.x1, r[2] or r.y1, r[3] or r.x2, r[4] or r.y2)
    return (x and x ~= -1), x or -1, y or -1
  end
  local x, y = M.findColor(sp.main, sp.offset or "", sp.sim or 90,
    r[1] or r.x1, r[2] or r.y1, r[3] or r.x2, r[4] or r.y2)
  return (x and x ~= -1), x or -1, y or -1
end

function M.matchIndex(name, index)
  -- 单点引擎：index>1 视为未命中（无多结果列表时）
  index = tonumber(index) or 1
  if index ~= 1 then return false, -1, -1 end
  return M.match(name)
end

function M.matchCoord(name)
  local ok, x, y = M.match(name)
  return x or -1, y or -1, ok
end

function M.matchSingle(name)
  return M.match(name)
end

--- 颜色相似度比较（0~100）
function M.colorCompare(c1, c2)
  c1, c2 = tonumber(c1) or 0, tonumber(c2) or 0
  local r1, g1, b1 = math.floor(c1 / 65536) % 256, math.floor(c1 / 256) % 256, c1 % 256
  local r2, g2, b2 = math.floor(c2 / 65536) % 256, math.floor(c2 / 256) % 256, c2 % 256
  local d = math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2)
  local sim = math.max(0, 100 - math.floor(d / 7.65))
  return sim
end

return M
