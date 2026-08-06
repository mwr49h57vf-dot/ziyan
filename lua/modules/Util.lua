--[[ Zy.Util — 通用工具（功能设计 P0）]]
local M = { name = "Util", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

function M.randomRange(a, b)
  a = tonumber(a) or 0
  b = tonumber(b) or a
  if b < a then a, b = b, a end
  return a + math.random() * (b - a)
end

function M.randomDelay(min_ms, max_ms)
  local ms = math.floor(M.randomRange(tonumber(min_ms) or 50, tonumber(max_ms) or 200))
  if defined("mSleep") then mSleep(ms) end
  return ms
end

function M.toast(text, ms)
  if defined("toast") then
    return toast(tostring(text or ""), tonumber(ms) or 1000)
  end
  return false
end

return M
