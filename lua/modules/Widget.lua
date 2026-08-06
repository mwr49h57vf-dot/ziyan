--[[ Zy.Widget — iOS 控件辅助（自研；非 Android Accessibility 私有 API）
  Division2 Wave4：
  - isAccessibilityOn：诚实探测（多数环境 false）
  - find/click/longClick：优先 OCR 找字 + Touch 点击（逻辑坐标）
  - scroll*/setText/region：尽力；无法完成时诚实返回 false
  风险：OCR 误识别导致错点；勿 tight-loop 无 mSleep。
]]
local M = { name = "Widget", version = "1.0.0", _last = nil }

local function defined(n) return type(_G[n]) == "function" end

local function tap_xy(x, y)
  x, y = tonumber(x), tonumber(y)
  if not x or not y then return false, "bad_xy" end
  if type(_G.Zy) == "table" and _G.Zy.Touch and type(_G.Zy.Touch.tap) == "function" then
    return _G.Zy.Touch.tap(x, y)
  end
  if defined("tap") then
    tap(x, y)
    return true
  end
  return false, "no_tap"
end

local function long_tap_xy(x, y, ms)
  ms = tonumber(ms) or 800
  if type(_G.Zy) == "table" and _G.Zy.Touch and type(_G.Zy.Touch.longTap) == "function" then
    return _G.Zy.Touch.longTap(x, y, ms)
  end
  if defined("touchDown") and defined("touchUp") then
    touchDown(1, x, y)
    if defined("mSleep") then mSleep(ms) end
    touchUp(1, x, y)
    return true
  end
  return tap_xy(x, y)
end

--- iOS 无 TS 式无障碍树；探测常见开关文件/进程
function M.isAccessibilityOn()
  if defined("isAccessibilityOn") and isAccessibilityOn ~= M.isAccessibilityOn then
    local v = isAccessibilityOn()
    return (v == true or v == 1)
  end
  -- VoiceOver / Switch Control 无稳定公共 API → 诚实 false
  return false
end

--- 找控件：用 OCR 找文案；成功缓存 _last={x,y,text}
function M.find(text, ...)
  text = tostring(text or "")
  if #text < 1 then return false end
  local x, y
  if type(_G.Zy) == "table" and _G.Zy.OCR then
    if type(_G.Zy.OCR.find) == "function" then
      x, y = _G.Zy.OCR.find(text, ...)
    elseif type(_G.Zy.OCR.findText) == "function" then
      x, y = _G.Zy.OCR.findText(text, ...)
    end
  end
  if (not x or x < 0) and defined("findStr") then
    x, y = findStr(0, 0, 0, 0, text, "FFFFFF", 0.9)
  end
  x, y = tonumber(x), tonumber(y)
  if x and y and x >= 0 and y >= 0 then
    M._last = { x = x, y = y, text = text }
    return true, x, y
  end
  return false
end

function M.region(x1, y1, x2, y2)
  M._region = {
    x1 = tonumber(x1) or 0,
    y1 = tonumber(y1) or 0,
    x2 = tonumber(x2) or 0,
    y2 = tonumber(y2) or 0,
  }
  return true
end

function M.click(a, b)
  if a ~= nil and b ~= nil then
    return tap_xy(a, b)
  end
  if type(a) == "string" then
    local ok, x, y = M.find(a)
    if not ok then return false, "not_found" end
    return tap_xy(x, y)
  end
  if M._last then
    return tap_xy(M._last.x, M._last.y)
  end
  return false, "no_target"
end

function M.longClick(a, b, ms)
  if a ~= nil and b ~= nil and type(a) ~= "string" then
    return long_tap_xy(a, b, ms)
  end
  if type(a) == "string" then
    local ok, x, y = M.find(a)
    if not ok then return false, "not_found" end
    return long_tap_xy(x, y, b or ms)
  end
  if M._last then
    return long_tap_xy(M._last.x, M._last.y, a or ms)
  end
  return false, "no_target"
end

function M.scrollForward()
  -- 屏幕中部上滑（逻辑坐标尽力）
  local w, h = 1136, 640
  if defined("getScreenSize") then
    local a, b = getScreenSize()
    w, h = tonumber(a) or w, tonumber(b) or h
  end
  local x, y1, y2 = math.floor(w / 2), math.floor(h * 0.7), math.floor(h * 0.3)
  if defined("swipe") then
    swipe(x, y1, x, y2, 300)
    return true
  end
  return false, "no_swipe"
end

function M.scrollBackward()
  local w, h = 1136, 640
  if defined("getScreenSize") then
    local a, b = getScreenSize()
    w, h = tonumber(a) or w, tonumber(b) or h
  end
  local x, y1, y2 = math.floor(w / 2), math.floor(h * 0.3), math.floor(h * 0.7)
  if defined("swipe") then
    swipe(x, y1, x, y2, 300)
    return true
  end
  return false, "no_swipe"
end

function M.setText(text)
  text = tostring(text or "")
  if defined("inputText") then
    inputText(text)
    return true
  end
  if defined("inputStr") then
    inputStr(text)
    return true
  end
  if type(_G.Zy) == "table" and _G.Zy.Input and type(_G.Zy.Input.text) == "function" then
    return _G.Zy.Input.text(text)
  end
  return false, "no_input"
end

return M
