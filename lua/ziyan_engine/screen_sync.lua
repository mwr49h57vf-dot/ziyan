--[[ Screen Synchronization Model（屏幕同步模型）
  真实屏幕(native) → 逻辑坐标(logic) → 游戏可视区(game_rect) → 设计分辨率(design)
  所有视觉识别 / 点击应经本层；禁止脚本直写死单机物理像素。
  依赖：Device.profile + Screen.screenSync + Coordinate
]]
local M = { module = "screen_sync", version = "1.1.0", model = "ScreenSynchronization" }

local function defined(n) return type(_G[n]) == "function" end

local function ensure_profile()
  if type(_G.__ZIYAN_DEVICE_PROFILE) ~= "table" then
    if defined("deviceRefresh") then
      pcall(deviceRefresh)
    elseif defined("deviceModel") then
      pcall(deviceModel)
    end
  end
  return _G.__ZIYAN_DEVICE_PROFILE
end

--- 同步屏幕（必须先于找色/OCR/点击）
function M.sync(orient, bid)
  orient = tonumber(orient) or tonumber(_G.__ZIYAN_ORIENT) or 1
  bid = bid or _G.__ZIYAN_LAST_BID
  if bid then _G.__ZIYAN_LAST_BID = bid end
  _G.__ZIYAN_ORIENT = orient
  ensure_profile()
  local ok = false
  if defined("screenSync") then
    ok = not not screenSync(orient, bid)
  elseif defined("syncGameScreen") then
    ok = not not syncGameScreen(orient, bid)
  elseif defined("softSync") then
    ok = not not softSync()
  end
  return ok
end

--- 当前映射快照（供设备库 / 调试）
function M.info()
  local p = ensure_profile() or {}
  local lw, lh = 0, 0
  if defined("screenSize") then
    lw, lh = screenSize()
  elseif defined("getScreenSize") then
    lw, lh = getScreenSize()
  end
  lw = tonumber(lw) or tonumber(p.logic_w) or 1136
  lh = tonumber(lh) or tonumber(p.logic_h) or 640
  local gx, gy, gw, gh = 0, 0, lw, lh
  if defined("deviceGameRect") then
    gx, gy, gw, gh = deviceGameRect()
  elseif type(p.game_rect) == "table" then
    gx, gy, gw, gh = p.game_rect.x, p.game_rect.y, p.game_rect.w, p.game_rect.h
  end
  return {
    native_w = tonumber(p.native_w) or 0,
    native_h = tonumber(p.native_h) or 0,
    scale = tonumber(p.scale) or 0,
    dpi = tonumber(p.dpi) or 0,
    orient = tonumber(p.orient) or tonumber(_G.__ZIYAN_ORIENT) or 1,
    logic_w = lw,
    logic_h = lh,
    game_x = tonumber(gx) or 0,
    game_y = tonumber(gy) or 0,
    game_w = tonumber(gw) or lw,
    game_h = tonumber(gh) or lh,
    model = tostring(p.model or ""),
    os = tostring(p.os or ""),
  }
end

--- 设计坐标 → 逻辑坐标（经游戏区裁剪）
function M.to_logic(dx, dy, design_w, design_h)
  if defined("coordPoint") then
    return coordPoint(dx, dy, design_w, design_h, true)
  end
  if defined("coordScale") then
    local lx, ly = coordScale(dx, dy, design_w, design_h)
    if defined("coordClampGame") then
      return coordClampGame(lx, ly)
    end
    return lx, ly
  end
  return tonumber(dx) or 0, tonumber(dy) or 0
end

--- 设计区域 → 逻辑区域
function M.to_region(x1, y1, x2, y2, design_w, design_h)
  if defined("coordRegion") then
    return coordRegion(x1, y1, x2, y2, design_w, design_h, true)
  end
  local a, b = M.to_logic(x1, y1, design_w, design_h)
  local c, d = M.to_logic(x2, y2, design_w, design_h)
  if a > c then a, c = c, a end
  if b > d then b, d = d, b end
  return a, b, c, d
end

--- 同步后点击设计坐标（强制经屏幕同步层）
function M.tap(dx, dy, design_w, design_h, hold_ms)
  M.sync(_G.__ZIYAN_ORIENT, _G.__ZIYAN_LAST_BID)
  if defined("coordTap") then
    return coordTap(dx, dy, design_w, design_h, hold_ms)
  end
  local lx, ly = M.to_logic(dx, dy, design_w, design_h)
  if defined("tap") then
    if hold_ms then return tap(lx, ly, hold_ms) end
    return tap(lx, ly)
  end
  return false, lx, ly
end

--- 同步后取色（逻辑点）
function M.get_color(lx, ly)
  M.sync(_G.__ZIYAN_ORIENT, _G.__ZIYAN_LAST_BID)
  if defined("getColor") then
    return tonumber(getColor(lx, ly)) or 0
  end
  return 0
end

--- 同步后按设计坐标取色
function M.get_color_design(dx, dy, design_w, design_h)
  local lx, ly = M.to_logic(dx, dy, design_w, design_h)
  return M.get_color(lx, ly), lx, ly
end

function M.install(engine)
  _G.screenSyncModel = M
  _G.syncScreen = function(orient, bid) return M.sync(orient, bid) end
  _G.syncInfo = function() return M.info() end
  _G.syncTap = function(dx, dy, dw, dh, hold) return M.tap(dx, dy, dw, dh, hold) end
  _G.syncToLogic = function(dx, dy, dw, dh) return M.to_logic(dx, dy, dw, dh) end
  _G.ZiYanScreenSync = M
  if engine then engine.screen_sync = M end
  return M
end

return M
