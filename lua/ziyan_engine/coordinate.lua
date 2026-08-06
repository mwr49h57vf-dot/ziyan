--[[ Coordinate 坐标转换（子砚自研）
  Device → Screen → Coordinate → Image/OCR/Touch
  设计分辨率缩放 + 游戏可视区裁剪；不写死单机像素。
]]
local M = { module = "coordinate", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

local function logic_size()
  if defined("getScreenSize") then
    local w, h = getScreenSize()
    return tonumber(w) or 1136, tonumber(h) or 640
  end
  local p = _G.__ZIYAN_DEVICE_PROFILE
  if type(p) == "table" then
    return tonumber(p.logic_w) or 1136, tonumber(p.logic_h) or 640
  end
  return 1136, 640
end

--- 设计分辨率坐标 → 当前逻辑坐标
function M.scale(x, y, design_w, design_h)
  x, y = tonumber(x) or 0, tonumber(y) or 0
  design_w = tonumber(design_w) or 0
  design_h = tonumber(design_h) or 0
  local lw, lh = logic_size()
  if design_w < 1 or design_h < 1 then
    return math.floor(x + 0.5), math.floor(y + 0.5)
  end
  local nx = x * lw / design_w
  local ny = y * lh / design_h
  return math.floor(nx + 0.5), math.floor(ny + 0.5)
end

--- 将点限制在游戏可视区（Device.game_rect）
function M.clamp_game(x, y)
  x, y = tonumber(x) or 0, tonumber(y) or 0
  local gx, gy, gw, gh = 0, 0, 0, 0
  if defined("deviceGameRect") then
    gx, gy, gw, gh = deviceGameRect()
  end
  gx, gy = tonumber(gx) or 0, tonumber(gy) or 0
  gw, gh = tonumber(gw) or 0, tonumber(gh) or 0
  if gw < 1 or gh < 1 then
    local lw, lh = logic_size()
    return math.max(0, math.min(lw - 1, x)), math.max(0, math.min(lh - 1, y))
  end
  local nx = math.max(gx, math.min(gx + gw - 1, x))
  local ny = math.max(gy, math.min(gy + gh - 1, y))
  return nx, ny
end

--- 设计坐标 → 逻辑点（可选裁剪到游戏区）
function M.point(x, y, design_w, design_h, clamp)
  local lx, ly = M.scale(x, y, design_w, design_h)
  if clamp ~= false then
    lx, ly = M.clamp_game(lx, ly)
  end
  return lx, ly
end

--- 设计区域 → 逻辑区域
function M.region(x1, y1, x2, y2, design_w, design_h, clamp)
  local a, b = M.point(x1, y1, design_w, design_h, clamp)
  local c, d = M.point(x2, y2, design_w, design_h, clamp)
  if a > c then a, c = c, a end
  if b > d then b, d = d, b end
  return a, b, c, d
end

--- 经 Coordinate 点击（禁止脚本绕过映射直接写死单机点时的推荐入口）
function M.tap(x, y, design_w, design_h, hold_ms)
  local lx, ly = M.point(x, y, design_w, design_h, true)
  if defined("screenSync") then
    pcall(screenSync, _G.__ZIYAN_ORIENT or 1, _G.__ZIYAN_LAST_BID)
  elseif defined("softSync") then
    pcall(softSync)
  end
  if defined("tap") then
    if hold_ms then
      return tap(lx, ly, hold_ms)
    end
    return tap(lx, ly)
  end
  return false, lx, ly
end

function M.install(engine)
  _G.coordScale = function(x, y, dw, dh) return M.scale(x, y, dw, dh) end
  _G.coordPoint = function(x, y, dw, dh, clamp) return M.point(x, y, dw, dh, clamp) end
  _G.coordRegion = function(x1, y1, x2, y2, dw, dh, clamp)
    return M.region(x1, y1, x2, y2, dw, dh, clamp)
  end
  _G.coordClampGame = function(x, y) return M.clamp_game(x, y) end
  _G.coordTap = function(x, y, dw, dh, hold) return M.tap(x, y, dw, dh, hold) end
  _G.ZiYanCoordinate = M
  if engine then engine.coordinate = M end
  return M
end

return M
