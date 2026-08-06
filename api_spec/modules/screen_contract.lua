-- ZiYan API contract: screen
-- 屏幕 / 取色 / 找色 / 截屏 / 方向
-- backend: lua/ziyan_engine/{cv,color,orient,screen}.lua + ZiYanScreenBridge
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'screen', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- init(orient:number) -> bool  [done]
--   0 Home下 1右 2左；逻辑坐标基准
-- 已实现：由 ziyan_engine 安装到 _G.init
M.init = _G.init  -- 运行时绑定（契约侧只读）

-- getColor(x, y) -> number  [done]
--   逻辑坐标取色 0xRRGGBB
-- 已实现：由 ziyan_engine 安装到 _G.getColor
M.getColor = _G.getColor  -- 运行时绑定（契约侧只读）

-- getColorRGB(x, y) -> r,g,b  [partial]
--   拆分 RGB
function M.getColorRGB(x, y)
  return NYI('getColorRGB')(x, y)
end

-- findColor(color) -> x,y  [partial]
--   全屏单色
function M.findColor(color)
  return NYI('findColor')(color)
end

-- findColorFuzzy(color, fuzzy) -> x,y  [partial]
--   全屏+精度
function M.findColorFuzzy(color, fuzzy)
  return NYI('findColorFuzzy')(color, fuzzy)
end

-- findColorInRegion(color, x1, y1, x2, y2) -> x,y  [partial]
--   区域单色
function M.findColorInRegion(color, x1, y1, x2, y2)
  return NYI('findColorInRegion')(color, x1, y1, x2, y2)
end

-- findColorInRegionFuzzy(color, fuzzy, x1, y1, x2, y2) -> x,y  [partial]
--   区域+精度
function M.findColorInRegionFuzzy(color, fuzzy, x1, y1, x2, y2)
  return NYI('findColorInRegionFuzzy')(color, fuzzy, x1, y1, x2, y2)
end

-- findMultiColorInRegionFuzzy(main, offsetStr, fuzzy, x1, y1, x2, y2) -> x,y  [done]
--   TS/TE 多点找色主路径
-- 已实现：由 ziyan_engine 安装到 _G.findMultiColorInRegionFuzzy
M.findMultiColorInRegionFuzzy = _G.findMultiColorInRegionFuzzy  -- 运行时绑定（契约侧只读）

-- findMultiColorInRegionFuzzyEx(main, offsetStr, fuzzy, x1, y1, x2, y2) -> table  [planned]
--   返回全部命中
function M.findMultiColorInRegionFuzzyEx(main, offsetStr, fuzzy, x1, y1, x2, y2)
  return NYI('findMultiColorInRegionFuzzyEx')(main, offsetStr, fuzzy, x1, y1, x2, y2)
end

-- keepScreen(on:boolean) -> void  [partial]
--   缓存开关（占位/桥接）
function M.keepScreen(on)
  return NYI('keepScreen')(on)
end

-- rotateScreen(deg:number) -> bool  [partial]
--   旋转提示（逻辑向由 init 管）
function M.rotateScreen(deg)
  return NYI('rotateScreen')(deg)
end

-- getScreenResolution() -> w,h  [partial]
--   逻辑分辨率
function M.getScreenResolution()
  return NYI('getScreenResolution')()
end

-- dumpScreen(path?:string) -> string|nil  [done]
--   逻辑方向 PNG
-- 已实现：由 ziyan_engine 安装到 _G.dumpScreen
M.dumpScreen = _G.dumpScreen  -- 运行时绑定（契约侧只读）

-- snapshot(path?:string) -> bool  [done]
--   截屏别名
-- 已实现：由 ziyan_engine 安装到 _G.snapshot
M.snapshot = _G.snapshot  -- 运行时绑定（契约侧只读）

-- snapshotRegion(path, x1, y1, x2, y2, scale?) -> bool  [partial]
--   区域截屏
function M.snapshotRegion(path, x1, y1, x2, y2, scale)
  return NYI('snapshotRegion')(path, x1, y1, x2, y2, scale)
end

function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
