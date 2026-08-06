--[[ Zy.String — 字符串/编码工具（自研纯 Lua + 引擎 util 门面，非 TS）
  分辨率无关；不触碰 Overlay/找色/触控内核。
]]
local M = { name = "String", version = "1.0.0" }

local function call_util(fn, ...)
  if type(_G.Zy) == "table" and type(_G.Zy.Compat) == "table"
      and type(_G.Zy.Compat.impl) == "table"
      and type(_G.Zy.Compat.impl.call) == "function" then
    return _G.Zy.Compat.impl.call("util." .. fn, ...)
  end
  local n = _G[fn]
  if type(n) == "function" then return n(...) end
  return nil
end

--- 去首尾空白
function M.trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.ltrim(s)
  return (tostring(s or ""):gsub("^%s+", ""))
end

function M.rtrim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end

function M.atrim(s)
  return M.trim(s)
end

--- 按分隔符切分（默认逗号）
function M.split(str, sep)
  local u = call_util("split", str, sep)
  if type(u) == "table" then return u end
  str, sep = tostring(str or ""), tostring(sep or ",")
  local t = {}
  for part in string.gmatch(str, "([^" .. sep .. "]+)") do
    t[#t + 1] = part
  end
  return t
end

function M.join(parts, sep)
  sep = tostring(sep or ",")
  if type(parts) ~= "table" then return tostring(parts or "") end
  return table.concat(parts, sep)
end

--- 0xRRGGBB ↔ RGB
function M.intToRgb(c)
  c = tonumber(c) or 0
  return math.floor(c / 0x10000) % 256, math.floor(c / 0x100) % 256, c % 256
end

function M.rgbToInt(r, g, b)
  r, g, b = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
  return r * 0x10000 + g * 0x100 + b
end

--- URL 编解码
function M.urlEncode(s)
  local u = call_util("urlEncode", s)
  if u then return u end
  s = tostring(s or "")
  return (s:gsub("([^%w%-_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function M.urlDecode(s)
  local u = call_util("urlDecode", s)
  if u then return u end
  s = tostring(s or ""):gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- 随机字符串（长度 + 可选字符集）
function M.random(len, charset)
  len = tonumber(len) or 8
  charset = tostring(charset or "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  if #charset < 1 then charset = "abc" end
  local out = {}
  for i = 1, len do
    local idx = math.random(1, #charset)
    out[i] = charset:sub(idx, idx)
  end
  return table.concat(out)
end

--- 统计字符串中数字个数
function M.countDigits(s)
  s = tostring(s or "")
  local n = 0
  for _ in s:gmatch("%d") do n = n + 1 end
  return n
end

--- 是否以 prefix 开头（忽略大小写可选）
function M.startsWith(s, prefix, ignore_case)
  s, prefix = tostring(s or ""), tostring(prefix or "")
  if ignore_case then
    return s:lower():sub(1, #prefix) == prefix:lower()
  end
  return s:sub(1, #prefix) == prefix
end

function M.endsWith(s, suffix, ignore_case)
  s, suffix = tostring(s or ""), tostring(suffix or "")
  if #suffix == 0 then return true end
  if ignore_case then
    return s:lower():sub(-#suffix) == suffix:lower()
  end
  return s:sub(-#suffix) == suffix
end

return M
