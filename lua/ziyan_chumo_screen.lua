--[[
  ziyan_chumo_screen.lua
  ------------------------------------------------------------
  自研移植自 deb分析/触摸精灵5.1.2/.../telib.lua「Screen」段（仅 API 形状与调用约定）。
  禁止链入 wnriakwyww / TSDaemon / 触动 dylib；底层一律走 ZiYan C：
    ziyan_embed_get_color / ziyan_embed_find_multi / ziyan_embed_keep_screen
    或全局 getColor / findMultiColorInRegionFuzzy / keepScreen

  对照：
    deb分析 telib.lua: getColor → _getColor；findMulti* → _findColor(json…)
    ZiYan：抓色器串格式 findMultiColorInRegionFuzzy(主色, "dx|dy|0x..", deg, ROI)
]]

local M = { name = "ziyan_chumo_screen", version = "1.0.0" }

local function bit_band(a, b)
  if bit32 and bit32.band then return bit32.band(a, b) end
  -- Lua 5.3+
  return a & b
end
local function bit_rshift(a, n)
  if bit32 and bit32.rshift then return bit32.rshift(a, n) end
  return a >> n
end

local function native_get_color(x, y)
  if type(_G.ziyan_embed_get_color) == "function" then
    local ok, c = pcall(_G.ziyan_embed_get_color, x, y)
    if ok then return tonumber(c) or -1 end
  end
  if type(_G._getColor) == "function" and _G._getColor ~= native_get_color then
    local ok, c = pcall(_G._getColor, x, y)
    if ok then return tonumber(c) or -1 end
  end
  return -1
end

--- 触动 _findColor(json colors, fuzzy, ltx,lty,rbx,rby, all)
--- colors: { color } 或 { {c,dx,dy}, ... } / { c= , dx=, dy= }
local function colors_to_main_offset(colors)
  if type(colors) ~= "table" then
    local c = tonumber(colors) or 0
    return c, ""
  end
  -- 纯数字数组：第一色为主，其余当同色偏点(0,0)无意义 → 只取主色
  if type(colors[1]) == "number" then
    return tonumber(colors[1]) or 0, ""
  end
  local first = colors[1]
  if type(first) ~= "table" then
    return tonumber(first) or 0, ""
  end
  local main = tonumber(first.color or first.c or first[3] or first[1]) or 0
  -- 若 [1] 是颜色且无 dx：主色=first[1]
  if first.dx == nil and first[2] == nil and type(first[1]) == "number" and first[3] == nil then
    main = tonumber(first[1]) or main
  end
  local parts = {}
  for i = 2, #colors do
    local p = colors[i]
    if type(p) == "table" then
      local dx = tonumber(p.dx or p[1]) or 0
      local dy = tonumber(p.dy or p[2]) or 0
      local col = tonumber(p.color or p.c or p[3]) or 0
      parts[#parts + 1] = string.format("%d|%d|0x%06X", dx, dy, col % 0x1000000)
    elseif type(p) == "number" then
      parts[#parts + 1] = string.format("0|0|0x%06X", (tonumber(p) or 0) % 0x1000000)
    end
  end
  -- 首点若带偏移：并入 offset，主色仍用其 color
  if first.dx ~= nil or first.dy ~= nil or (first[2] ~= nil and first[3] ~= nil) then
    local dx0 = tonumber(first.dx or first[1]) or 0
    local dy0 = tonumber(first.dy or first[2]) or 0
    local col0 = tonumber(first.color or first.c or first[3]) or main
    if first[3] ~= nil then
      dx0 = tonumber(first[1]) or 0
      dy0 = tonumber(first[2]) or 0
      col0 = tonumber(first[3]) or main
      main = col0
    end
    if dx0 ~= 0 or dy0 ~= 0 then
      table.insert(parts, 1, string.format("%d|%d|0x%06X", dx0, dy0, col0 % 0x1000000))
    else
      main = col0
    end
  end
  return main, table.concat(parts, ",")
end

function M.install()
  -- 抓色器/引擎已装好的实现（禁包装递归）
  local orig_fmc = rawget(_G, "findMultiColorInRegionFuzzy")
  local orig_keep = rawget(_G, "keepScreen")

  local function call_fmc(main, offset, fuzzy, x1, y1, x2, y2)
    if type(orig_fmc) == "function" then
      local ok, x, y = pcall(orig_fmc, main, offset or "", fuzzy or 90, x1, y1, x2, y2)
      if ok then return tonumber(x) or -1, tonumber(y) or -1 end
    end
    if type(_G.ziyan_embed_find_multi) == "function" then
      -- embed 要 JSON 点列；单点主色
      local json = string.format("[{\"c\":%d,\"dx\":0,\"dy\":0}]", tonumber(main) or 0)
      local ok, x, y = pcall(_G.ziyan_embed_find_multi, json, fuzzy or 90, x1 or 0, y1 or 0, x2 or -1, y2 or -1)
      if ok then return tonumber(x) or -1, tonumber(y) or -1 end
    end
    return -1, -1
  end

  -- 与 telib 一致：_getColor / getColor / getColorRGB
  _G._getColor = function(x, y)
    return native_get_color(tonumber(x) or 0, tonumber(y) or 0)
  end

  _G.getColor = function(x, y)
    return _G._getColor(x, y)
  end

  _G.getColorRGB = function(x, y)
    local c = _G._getColor(x, y)
    if c == nil or tonumber(c) == -1 then
      return -1, -1, -1
    end
    c = tonumber(c) or 0
    local r = bit_band(bit_rshift(c, 16), 0xff)
    local g = bit_band(bit_rshift(c, 8), 0xff)
    local b = bit_band(c, 0xff)
    return r, g, b
  end

  local function find_color_one(colors, fuzzy, ltx, lty, rbx, rby)
    local main, offset = colors_to_main_offset(colors)
    return call_fmc(main, offset, fuzzy or 100, ltx or 0, lty or 0, rbx or -1, rby or -1)
  end

  _G.findColor = function(color)
    return find_color_one({ color }, 100, 0, 0, -1, -1)
  end

  _G.findColorFuzzy = function(color, fuzzy)
    return find_color_one({ color }, fuzzy, 0, 0, -1, -1)
  end

  _G.findColorInRegion = function(color, ltx, lty, rbx, rby)
    return find_color_one({ color }, 100, ltx, lty, rbx, rby)
  end

  _G.findColorInRegionFuzzy = function(color, fuzzy, ltx, lty, rbx, rby)
    return find_color_one({ color }, fuzzy, ltx, lty, rbx, rby)
  end

  -- 触动表形 + 抓色器串形双通道
  _G.findMultiColorInRegionFuzzy = function(a, b, c, d, e, f, g)
    if type(a) == "table" then
      return find_color_one(a, b, c, d, e, f)
    end
    return call_fmc(tonumber(a) or 0, tostring(b or ""), tonumber(c) or 90, d, e, f, g)
  end

  _G.findMultiColor = function(...)
    return _G.findMultiColorInRegionFuzzy(...)
  end

  if type(_G.ziyan_embed_keep_screen) == "function" then
    _G.keepScreen = function(on, _colors, _fuzzy)
      return _G.ziyan_embed_keep_screen(not not on)
    end
  elseif type(orig_keep) == "function" then
    _G.keepScreen = orig_keep
  else
    _G.keepScreen = function(_on)
      return false
    end
  end

  _G.__ZIYAN_CHUMO_SCREEN = M.version
  return true
end

return M
