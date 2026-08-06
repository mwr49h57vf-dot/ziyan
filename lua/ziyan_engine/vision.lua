--[[ Vision 视觉分析门面（子砚自研）
  调度 Image(cv) + OCR(py_cv) + 色参；所有区域经 Coordinate。
  不调用 TouchSprite API。
]]
local M = { module = "vision", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

local function ensure_screen()
  -- 仅 soft 对齐 init 朝向；禁止 keepScreen 开关风暴（占帧/升 CPU）
  if defined("softSync") then
    pcall(softSync)
  elseif defined("screenSync") then
    pcall(screenSync, _G.__ZIYAN_ORIENT or 1, _G.__ZIYAN_LAST_BID)
  end
end

local function map_region(x1, y1, x2, y2, dw, dh)
  if dw and dh and defined("coordRegion") then
    return coordRegion(x1, y1, x2, y2, dw, dh, true)
  end
  return tonumber(x1) or 0, tonumber(y1) or 0, tonumber(x2) or 0, tonumber(y2) or 0
end

--- 区域 OCR（默认不落盘截图）
-- 返回: ok, text, via
function M.ocr(x1, y1, x2, y2, design_w, design_h)
  ensure_screen()
  x1, y1, x2, y2 = map_region(x1, y1, x2, y2, design_w, design_h)
  local text, via = "", "none"
  if defined("getText") then
    local ok, a = pcall(getText, x1, y1, x2, y2)
    if ok and type(a) == "string" then text, via = a, "getText" end
  end
  if text == "" and defined("strFind") then
    local ok, a = pcall(strFind, x1, y1, x2, y2)
    if ok and type(a) == "string" then text, via = a, "strFind" end
  end
  local ok = text ~= nil and #tostring(text) > 0
  return ok, text or "", via, x1, y1, x2, y2
end

--- 找字；失败返回 -1
function M.find_text(word, x1, y1, x2, y2, design_w, design_h)
  ensure_screen()
  x1, y1, x2, y2 = map_region(x1, y1, x2, y2, design_w, design_h)
  if type(findStr) == "function" then
    local ok, fx, fy = pcall(findStr, word, x1, y1, x2, y2)
    if ok and fx and fx ~= -1 then
      return fx, fy, "findStr"
    end
  end
  return -1, -1, "miss"
end

--- 多点找色（与抓色器同参：主色 + "dx|dy|0x.." + degree + ROI）
function M.find_color(main, offset, sim, x1, y1, x2, y2, design_w, design_h)
  ensure_screen()
  x1, y1, x2, y2 = map_region(x1, y1, x2, y2, design_w, design_h)
  if not defined("findMultiColorInRegionFuzzy") then
    return -1, -1, "no_api"
  end
  local fx, fy = findMultiColorInRegionFuzzy(
    main, offset or "", tonumber(sim) or 90, x1, y1, x2, y2)
  fx, fy = tonumber(fx) or -1, tonumber(fy) or -1
  if fx ~= -1 then
    return fx, fy, "color"
  end
  return -1, -1, "miss"
end

--- 抓色器同名入口（无 design 映射时直接透传）
function M.findMultiColorInRegionFuzzy(main, offset, degree, x1, y1, x2, y2)
  if not defined("findMultiColorInRegionFuzzy") then
    return -1, -1
  end
  local fx, fy = findMultiColorInRegionFuzzy(
    main, offset or "", tonumber(degree) or 90, x1 or 0, y1 or 0, x2 or -1, y2 or -1)
  return tonumber(fx) or -1, tonumber(fy) or -1
end

function M.findMultiColor(...)
  return M.findMultiColorInRegionFuzzy(...)
end

--- 多方案：OCR 词表 → 找色；附带命中点 getColor
-- 返回: hit, kind, x, y, color, detail
function M.analyze(opts)
  opts = opts or {}
  ensure_screen()
  local words = opts.words or {}
  local dw, dh = opts.design_w, opts.design_h
  local x1 = opts.x1 or 0
  local y1 = opts.y1 or 0
  local lw, lh = 1136, 640
  if defined("screenSize") then lw, lh = screenSize() end
  local x2 = opts.x2 or (lw - 1)
  local y2 = opts.y2 or (lh - 1)

  for _, w in ipairs(words) do
    local fx, fy, via = M.find_text(w, x1, y1, x2, y2, dw, dh)
    if fx ~= -1 then
      local c = 0
      if defined("getColor") then c = tonumber(getColor(fx, fy)) or 0 end
      return true, "ocr", fx, fy, c, { word = w, via = via }
    end
  end

  if opts.main_color then
    local fx, fy, via = M.find_color(
      opts.main_color, opts.offset, opts.sim or 70,
      x1, y1, x2, y2, dw, dh)
    if fx ~= -1 then
      local c = 0
      if defined("getColor") then c = tonumber(getColor(fx, fy)) or 0 end
      return true, "color", fx, fy, c, { via = via }
    end
  end

  -- 色参探针（不截图）
  if defined("gameOcrColorProbe") and #words > 0 then
    local hit, word, x, y, c = gameOcrColorProbe(words, x1, y1, x2, y2)
    if hit and x and x ~= -1 then
      return true, "ocr_color", x, y, c or 0, { word = word }
    end
  end

  return false, "none", -1, -1, 0, { reason = "all_miss" }
end

function M.install(engine)
  _G.visionOcr = function(x1, y1, x2, y2, dw, dh)
    return M.ocr(x1, y1, x2, y2, dw, dh)
  end
  _G.visionFindText = function(word, x1, y1, x2, y2, dw, dh)
    return M.find_text(word, x1, y1, x2, y2, dw, dh)
  end
  _G.visionFindColor = function(main, offset, sim, x1, y1, x2, y2, dw, dh)
    return M.find_color(main, offset, sim, x1, y1, x2, y2, dw, dh)
  end
  _G.visionAnalyze = function(opts) return M.analyze(opts) end
  _G.ZiYanVision = M
  if engine then engine.vision = M end
  return M
end

return M
