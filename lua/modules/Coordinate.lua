--[[ Zy.Coordinate — 坐标转换模块
  设计分辨率 / 比例 → 逻辑点；禁止用户脚本写死物理像素。
]]
local C = require("modules._ctx")
local M = { name = "Coordinate", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

--- 设定设计分辨率（脚本必调）
function M.setDesign(w, h)
  C.require_pipeline("coordinate")
  return C.set_design(w, h)
end

function M.design()
  return C.design_w, C.design_h
end

--- 设计坐标 → 逻辑坐标
function M.point(dx, dy)
  C.require_pipeline("coordinate")
  local dw, dh = C.require_design()
  if defined("syncToLogic") then return syncToLogic(dx, dy, dw, dh) end
  if defined("coordPoint") then return coordPoint(dx, dy, dw, dh, true) end
  return tonumber(dx) or 0, tonumber(dy) or 0
end

--- 比例坐标 (0~1) → 逻辑坐标
function M.ratio(rx, ry)
  C.require_pipeline("coordinate")
  rx, ry = tonumber(rx) or 0, tonumber(ry) or 0
  local dw, dh = C.design_w, C.design_h
  if dw and dh then
    return M.point(rx * dw, ry * dh)
  end
  local Screen = require("modules.Screen")
  local w, h = Screen.size()
  local lx = math.floor(rx * w + 0.5)
  local ly = math.floor(ry * h + 0.5)
  if defined("coordClampGame") then return coordClampGame(lx, ly) end
  return lx, ly
end

function M.region(x1, y1, x2, y2)
  C.require_pipeline("coordinate")
  local dw, dh = C.require_design()
  if defined("coordRegion") then
    return coordRegion(x1, y1, x2, y2, dw, dh, true)
  end
  local a, b = M.point(x1, y1)
  local c, d = M.point(x2, y2)
  if a > c then a, c = c, a end
  if b > d then b, d = d, b end
  return a, b, c, d
end

return M
