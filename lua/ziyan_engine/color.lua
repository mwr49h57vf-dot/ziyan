--[[ 找色/找图：与子砚抓色器生成代码同架构
  规范（抓色器 / 触动）：
    x, y = findMultiColorInRegionFuzzy(0x主色, "dx|dy|0x..,...", degree, x1,y1,x2,y2)
  别名 findMultiColor 同参；偏点相对首点；degree 常 90。
  TE 兼容扁平表: {锚点色, dx,dy,色, ...} 仍可作第 1 参（无偏点串时）。
]]
local M = {}

local function defined(n) return type(_G[n]) == "function" end

local function O()
  return _G.ZiYanOrient
end

local function checkpoint()
  if type(_G.__ZIYAN_wait_while_paused) == "function" then
    _G.__ZIYAN_wait_while_paused()
  end
  local Ori = O()
  local now = os.clock()
  -- 前台切换：自动与游戏画面再对齐（自有 sync）
  if type(frontAppBid) == "function" then
    local front = frontAppBid() or ""
    if front ~= (_G.__ZIYAN_LAST_FRONT or "") then
      _G.__ZIYAN_LAST_FRONT = front
      if type(syncGameScreen) == "function" then
        pcall(syncGameScreen, _G.__ZIYAN_ORIENT or 1, front)
      elseif Ori and type(Ori.soft_sync) == "function" then
        pcall(Ori.soft_sync)
      end
    end
  end
  if Ori and type(Ori.refresh_buffer) == "function" then
    if not _G.__ZIYAN_BUF_REFRESH_T or (now - _G.__ZIYAN_BUF_REFRESH_T) > 1.5 then
      _G.__ZIYAN_BUF_REFRESH_T = now
      pcall(Ori.refresh_buffer)
    end
  end
end

local function wrap_once(name, wrapper)
  if not defined(name) or _G["__ZIYAN_ORIENT_WRAP_" .. name] then
    return
  end
  local native = _G[name]
  _G[name] = wrapper(native)
  _G["__ZIYAN_ORIENT_WRAP_" .. name] = true
  _G["__ZIYAN_NATIVE_" .. name] = native
end

--- 任意输入 → TE 扁平表 {c0, dx,dy,c1, ...}，并按 Home 方位旋转偏移
local function to_te_flat(colors, Ori)
  if type(colors) ~= "table" then
    return { tonumber(colors) or 0 }
  end
  local flat = {}
  if type(colors[1]) == "number" then
    -- 已是扁平，或单色 {c}
    flat[1] = tonumber(colors[1]) or 0
    local i = 2
    while i + 2 <= #colors do
      local dx = tonumber(colors[i]) or 0
      local dy = tonumber(colors[i + 1]) or 0
      local col = tonumber(colors[i + 2]) or 0
      if Ori then
        dx, dy = Ori.offset_to_phys(dx, dy)
      end
      flat[#flat + 1] = dx
      flat[#flat + 1] = dy
      flat[#flat + 1] = col
      i = i + 3
    end
    return flat
  end
  -- 嵌套 {{c,dx,dy}, ...} 或 {{c,0,0},{c,dx,dy}}
  for i, c in ipairs(colors) do
    if type(c) == "table" then
      local col = tonumber(c[1] or c.color) or 0
      local dx = tonumber(c[2] or c.x) or 0
      local dy = tonumber(c[3] or c.y) or 0
      if i == 1 then
        flat[1] = col
      else
        if Ori then
          dx, dy = Ori.offset_to_phys(dx, dy)
        end
        flat[#flat + 1] = dx
        flat[#flat + 1] = dy
        flat[#flat + 1] = col
      end
    elseif type(c) == "number" and i == 1 then
      flat[1] = c
    end
  end
  if #flat == 0 then
    flat[1] = 0
  end
  return flat
end

local function parse_ts_string(color, offsetStr, Ori)
  local flat = { tonumber(color) or 0 }
  if type(offsetStr) == "string" and offsetStr ~= "" then
    for part in string.gmatch(offsetStr, "[^,]+") do
      local dx, dy, col = string.match(part, "([^|]+)|([^|]+)|([^|]+)")
      if dx then
        dx, dy = tonumber(dx) or 0, tonumber(dy) or 0
        -- TSColorPicker / ScreenBridge 用逻辑坐标；不再 offset_to_phys
        -- （竖线偏移被旋转后会找错）。TE 原生缓冲路径由 cv.lua 接管 TS。
        flat[#flat + 1] = dx
        flat[#flat + 1] = dy
        flat[#flat + 1] = tonumber(col) or 0
      end
    end
  end
  return flat
end

function M.install()
  wrap_once("getColor", function(native)
    return function(x, y)
      checkpoint()
      -- 仅 TE 竖屏缓冲兜底需要 to_phys；ScreenBridge/cv 已覆盖 getColor（逻辑坐标）
      local Ori = O()
      if Ori then
        x, y = Ori.to_phys(x, y)
      end
      return native(x, y)
    end
  end)

  if defined("getColorRGB") then
    wrap_once("getColorRGB", function(native)
      return function(x, y)
        checkpoint()
        local Ori = O()
        if Ori then
          x, y = Ori.to_phys(x, y)
        end
        return native(x, y)
      end
    end)
  end

  wrap_once("findColor", function(native)
    return function(color)
      checkpoint()
      local Ori = O()
      local x, y = native(color)
      if Ori and x and y and x >= 0 and y >= 0 then
        return Ori.to_logic(x, y)
      end
      return x, y
    end
  end)

  wrap_once("findColorFuzzy", function(native)
    return function(color, fuzzy)
      checkpoint()
      local Ori = O()
      local x, y = native(color, fuzzy)
      if Ori and x and y and x >= 0 and y >= 0 then
        return Ori.to_logic(x, y)
      end
      return x, y
    end
  end)

  wrap_once("findColorInRegionFuzzy", function(native)
    return function(color, fuzzy, ltx, lty, rbx, rby)
      checkpoint()
      local Ori = O()
      if Ori then
        ltx, lty, rbx, rby = Ori.rect_to_phys(ltx, lty, rbx, rby)
      end
      local x, y = native(color, fuzzy, ltx, lty, rbx, rby)
      if Ori and x and y and x >= 0 and y >= 0 then
        return Ori.to_logic(x, y)
      end
      return x, y
    end
  end)

  wrap_once("findColorInRegion", function(native)
    return function(color, ltx, lty, rbx, rby)
      checkpoint()
      local Ori = O()
      if Ori then
        ltx, lty, rbx, rby = Ori.rect_to_phys(ltx, lty, rbx, rby)
      end
      local x, y = native(color, ltx, lty, rbx, rby)
      if Ori and x and y and x >= 0 and y >= 0 then
        return Ori.to_logic(x, y)
      end
      return x, y
    end
  end)

  -- TE: findMultiColorInRegionFuzzy(flatColors, fuzzy, ltx, lty, rbx, rby)
  -- TS: 由后续 cv.lua 接管（ScreenBridge）；此处仅包装 TE 扁平原生
  -- 201：TS 字符串路径唯一边界=CV（逻辑坐标）；禁止本层再 Ori.rect/offset 双重变换
  wrap_once("findMultiColorInRegionFuzzy", function(native)
    return function(a, b, c, d, e, f, g, h)
      checkpoint()
      -- TS 字符串：不在此处理（避免 Ori 旋转偏移）；交给已安装的 cv 或原样透传
      if type(b) == "string" then
        if type(_G.ZiYanCV_Native) == "table"
            and type(_G.ZiYanCV_Native.findMultiColorInRegionFuzzy) == "function" then
          return _G.ZiYanCV_Native.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
        end
        if type(_G.ZiYanCV) == "table"
            and type(_G.ZiYanCV.findMultiColorInRegionFuzzy) == "function" then
          return _G.ZiYanCV.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
        end
        -- cv 尚未装：解析但不旋转偏移，走原生（ROI/偏点保持脚本逻辑坐标）
        local x1, y1, x2, y2 = d, e, f, g
        local flat = parse_ts_string(a, b, nil)
        local x, y = native(flat, c or 90, x1, y1, x2, y2)
        return x, y
      end

      -- TE 表参数：若 CV 已接管全局，原生已是 CV——禁再 phys 变换
      if type(_G.ZiYanCV_Native) == "table"
          and type(_G.ZiYanCV_Native.findMultiColorInRegionFuzzy) == "function"
          and native == _G.ZiYanCV_Native.findMultiColorInRegionFuzzy then
        return native(a, b, c, d, e, f, g)
      end

      local Ori = O()
      local colors, fuzzy, ltx, lty, rbx, rby = a, b, c, d, e, f
      if Ori then
        ltx, lty, rbx, rby = Ori.rect_to_phys(ltx, lty, rbx, rby)
      end
      local flat = to_te_flat(colors, Ori)
      local x, y = native(flat, fuzzy, ltx, lty, rbx, rby)
      if Ori and x and y and x >= 0 and y >= 0 then
        return Ori.to_logic(x, y)
      end
      return x, y
    end
  end)

  wrap_once("findMultiColorInRegionFuzzyEx", function(native)
    return function(colors, fuzzy, ltx, lty, rbx, rby)
      checkpoint()
      local Ori = O()
      if Ori then
        ltx, lty, rbx, rby = Ori.rect_to_phys(ltx, lty, rbx, rby)
      end
      local flat = to_te_flat(colors, Ori)
      local t = native(flat, fuzzy, ltx, lty, rbx, rby)
      if Ori and type(t) == "table" then
        for _, p in ipairs(t) do
          if type(p) == "table" and p.x and p.y then
            p.x, p.y = Ori.to_logic(p.x, p.y)
          end
        end
      end
      return t
    end
  end)

  for _, name in ipairs({
    "findImage", "findImageFuzzy", "findImageInRegion", "findImageInRegionFuzzy",
  }) do
    wrap_once(name, function(native)
      return function(...)
        checkpoint()
        local args = { ... }
        local Ori = O()
        if Ori and #args >= 5 then
          if name == "findImageInRegion" or name == "findImageInRegionFuzzy" then
            local i = (name == "findImageInRegionFuzzy") and 3 or 2
            if args[i] and args[i + 3] then
              args[i], args[i + 1], args[i + 2], args[i + 3] =
                Ori.rect_to_phys(args[i], args[i + 1], args[i + 2], args[i + 3])
            end
          end
        end
        local x, y = native(unpack(args))
        if Ori and x and y and tonumber(x) and tonumber(x) >= 0 then
          return Ori.to_logic(x, y)
        end
        return x, y
      end
    end)
  end

  -- 始终提供与抓色器一致的别名（覆盖空 stub）
  if defined("findMultiColorInRegionFuzzy") then
    function findMultiColor(color, posandcolors, degree, x1, y1, x2, y2, tb)
      return findMultiColorInRegionFuzzy(color, posandcolors, degree, x1, y1, x2, y2, tb)
    end
  end

  if not defined("getPixelColor") and defined("getColor") then
    function getPixelColor(x, y)
      return getColor(x, y)
    end
  end

  _G.__ZIYAN_TO_TE_FLAT = to_te_flat
  return M
end

return M
