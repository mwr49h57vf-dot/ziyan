--[[ Zy.OCR — 文字识别模块
  Zy.OCR.region(x1,y1,x2,y2)
    · 坐标系：与 init(0/1/2) 逻辑坐标一致（同 findMultiColor / getText）
    · 若已 Coordinate.setDesign 且与当前逻辑屏不同，则按设计坐标映射到逻辑
    · 返回：识别到非空文字 → string；否则 → nil
  内存：不锁 keepScreen；走 getText/SB Vision（默认不落盘全屏）；用完依赖引擎 cleanup
]]
local C = require("modules._ctx")
local M = { name = "OCR", version = "1.2.0" }

local function defined(n) return type(_G[n]) == "function" end

-- 8-156：OCR 白名单（字符集过滤）；写入 var 供引擎侧读取
local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

--- 设置白名单字符（string）；nil/false/"" 清除
function M.setWhitelist(chars)
  if chars == nil or chars == false or chars == "" then
    M._whitelist = nil
    pcall(os.remove, var_dir() .. "/.ziyan_ocr_whitelist")
    return true
  end
  local s = tostring(chars)
  M._whitelist = s
  local f = io.open(var_dir() .. "/.ziyan_ocr_whitelist", "w")
  if not f then
    return false
  end
  f:write(s)
  f:close()
  return true
end

function M.getWhitelist()
  if type(M._whitelist) == "string" then
    return M._whitelist
  end
  local f = io.open(var_dir() .. "/.ziyan_ocr_whitelist", "r")
  if not f then
    return nil
  end
  local s = f:read("*a") or ""
  f:close()
  if s == "" then
    return nil
  end
  M._whitelist = s
  return s
end

--- 按白名单过滤文本（无白名单则原样返回）
function M.applyWhitelist(text)
  local wl = M.getWhitelist()
  text = tostring(text or "")
  if not wl or wl == "" then
    return text
  end
  local allow = {}
  -- UTF-8 安全：按字节串匹配白名单子串（ASCII 白名单最稳）
  if not wl:find("[\128-\255]") then
    for i = 1, #wl do
      allow[wl:sub(i, i)] = true
    end
    local out = {}
    for i = 1, #text do
      local ch = text:sub(i, i)
      if allow[ch] then
        out[#out + 1] = ch
      end
    end
    return table.concat(out)
  end
  return text
end

local function trim_text(s)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" or not s:find("%S") then
    return nil
  end
  return s
end

--- 与 init 对齐：统一 ForegroundFrameGate（不锁 keep，不落盘）
local function sync_init_logic()
  local orient = tonumber(_G.__ZIYAN_ORIENT) or tonumber(_G.__ZIYAN_TE_ORIENT) or tonumber(C.orient) or 1
  if orient < 0 or orient > 2 then
    orient = 1
  end
  C.orient = orient
  _G.__ZIYAN_ORIENT = orient
  pcall(function()
    local cv = package.loaded["ziyan_engine.cv"] or package.loaded["ziyan_engine/cv"]
    if type(cv) == "table" and type(cv.vision_gate) == "function" then
      cv.vision_gate("ocr")
      return
    end
    if type(cv) == "table" and type(cv.ensure_foreground_frame) == "function" then
      cv.ensure_foreground_frame()
      return
    end
    if type(ZiYanOrient) == "table" and type(ZiYanOrient.reassert_init_orient) == "function" then
      ZiYanOrient.reassert_init_orient()
    end
  end)
end

--- 区域 → 逻辑坐标（init 同系；有 setDesign 且与逻辑屏不一致时做映射）
local function to_logic_region(x1, y1, x2, y2)
  x1 = math.floor(tonumber(x1) or 0)
  y1 = math.floor(tonumber(y1) or 0)
  x2 = math.floor(tonumber(x2) or -1)
  y2 = math.floor(tonumber(y2) or -1)
  local dw, dh = C.design_w, C.design_h
  local lw, lh = 0, 0
  pcall(function()
    local S = require("modules.Screen")
    lw, lh = S.size()
    lw, lh = tonumber(lw) or 0, tonumber(lh) or 0
  end)
  if (not dw or not dh) and lw > 0 and lh > 0 then
    dw, dh = lw, lh
    C.design_w, C.design_h = dw, dh
  end
  if dw and dh and lw > 0 and lh > 0 and (dw ~= lw or dh ~= lh) and defined("coordRegion") then
    return coordRegion(x1, y1, x2, y2, dw, dh, true)
  end
  return x1, y1, x2, y2
end

--- 区域识字（逻辑坐标，支持 init）
--- @return string|nil 有识别文字返回正文；无/失败返回 nil
function M.region(x1, y1, x2, y2)
  pcall(function()
    C.require_pipeline("vision")
  end)
  sync_init_logic()
  -- 179：找字也跟前台（与 cv.ensure_foreground_frame 一致）
  pcall(function()
    local cv = package.loaded["ziyan_engine.cv"] or package.loaded["ziyan_engine/cv"]
    if type(cv) == "table" and type(cv.ensure_foreground_frame) == "function" then
      cv.ensure_foreground_frame()
    end
  end)
  x1, y1, x2, y2 = to_logic_region(x1, y1, x2, y2)

  local text = nil
  -- 主路径：getText（py_cv → SB Vision ROI，默认不落盘全屏）
  if defined("getText") then
    local ok, a = pcall(getText, x1, y1, x2, y2)
    if ok then
      if type(a) == "string" then
        text = a
      elseif type(a) == "table" and type(a.text) == "string" then
        text = a.text
      end
    end
  end
  -- 回退：visionOcr（返回 ok, text, via）
  if (not text or not tostring(text):find("%S")) and defined("visionOcr") then
    local pack = { pcall(visionOcr, x1, y1, x2, y2, C.design_w, C.design_h) }
    if pack[1] then
      if type(pack[3]) == "string" then
        text = pack[3]
      elseif type(pack[2]) == "string" then
        text = pack[2]
      end
    end
  end

  text = trim_text(text)
  if not text then
    return nil
  end
  text = trim_text(M.applyWhitelist(text))
  return text
end

--- 设计区域内找字
function M.find(word, x1, y1, x2, y2)
  C.require_pipeline("vision")
  sync_init_logic()
  local dw, dh = C.require_design()
  x1, y1, x2, y2 = to_logic_region(x1, y1, x2, y2)
  if defined("visionFindText") then
    local fx, fy, via = visionFindText(word, x1, y1, x2, y2, dw, dh)
    fx, fy = tonumber(fx), tonumber(fy)
    if fx and fy and fx >= 0 and fy >= 0 then
      return fx, fy, via or "vision"
    end
    return -1, -1, via or "miss"
  end
  if defined("findStr") then
    local ok, fx, fy = pcall(findStr, word, x1, y1, x2, y2)
    fx, fy = tonumber(fx), tonumber(fy)
    if ok and fx and fy and fx >= 0 and fy >= 0 then
      return fx, fy, "findStr"
    end
  end
  return -1, -1, "miss"
end

--- 词表分析（OCR→色）
function M.analyze(opts)
  C.require_pipeline("vision")
  opts = opts or {}
  opts.design_w = opts.design_w or C.design_w
  opts.design_h = opts.design_h or C.design_h
  if defined("visionAnalyze") then
    return visionAnalyze(opts)
  end
  return false, "none", -1, -1, 0, { reason = "no_vision" }
end

--- 超时内轮询找字（Until 思想）
function M.findUntil(word, x1, y1, x2, y2, timeout_ms, interval_ms)
  timeout_ms = tonumber(timeout_ms) or 5000
  interval_ms = tonumber(interval_ms) or 400
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < timeout_ms do
    local fx, fy, via = M.find(word, x1, y1, x2, y2)
    if fx and fx ~= -1 then
      return true, fx, fy, via
    end
    if defined("mSleep") then
      mSleep(interval_ms)
    end
  end
  return false, -1, -1, "timeout"
end

return M
