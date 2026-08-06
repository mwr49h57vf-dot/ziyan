--[[ Zy.Network — 网络模块（子砚 IPC / HTTP 门面，非 TS）
  临时文件优先 ZIYAN_VAR，避免 Media 目录权限/缓存问题。
]]
local M = { name = "Network", version = "1.2.0", _timeout = 8 }

local function defined(n) return type(_G[n]) == "function" end

local function varDir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function tmpPath(suffix)
  return varDir() .. "/" .. (suffix or ".zy_http_out.txt")
end

function M.setTimeout(sec)
  M._timeout = math.max(1, tonumber(sec) or 8)
  _G.__ZIYAN_HTTP_TIMEOUT = M._timeout
  return M._timeout
end

function M.timeout()
  return M._timeout
end

--- URL 参数字符串拼接（等价 httpBuildQuery）
function M.httpBuildQuery(tbl)
  if type(tbl) ~= "table" then return "" end
  local parts = {}
  for k, v in pairs(tbl) do
    local key = tostring(k)
    if type(v) == "table" then
      for i, item in ipairs(v) do
        parts[#parts + 1] = string.format("%s[%d]=%s",
          M.urlEncode(key), i, M.urlEncode(tostring(item)))
      end
    else
      parts[#parts + 1] = string.format("%s=%s", M.urlEncode(key), M.urlEncode(tostring(v)))
    end
  end
  return table.concat(parts, "&")
end

function M.urlEncode(s)
  s = tostring(s or "")
  return (s:gsub("([^%w%-_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function M.urlDecode(s)
  s = tostring(s or ""):gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Lua↔Python：pyCall(module, func, args)
function M.pyCall(mod, func, args, opts)
  if defined("pyCall") then
    return pyCall(mod, func, args, opts)
  end
  return false, "no_pyCall"
end

--- 简易 HTTP GET（经 py 或 curl 兜底；body 写入 ZIYAN_VAR 临时文件）
function M.httpGet(url, timeout)
  timeout = tonumber(timeout) or M._timeout or 8
  url = tostring(url or "")
  if url == "" then return false, "empty_url" end
  if defined("pyCall") then
    local ok, res = pyCall("ziyan_net", "http_get", { url = url, timeout = timeout })
    if ok then return true, res end
  end
  -- 引擎 py_cv 全局 httpGet 返回 body 字符串
  if defined("httpGet") and httpGet ~= M.httpGet then
    local body = httpGet(url, timeout)
    if type(body) == "string" and body ~= "" then return true, body end
  end
  local out = tmpPath(".zy_http_get_out.txt")
  local cmd = string.format(
    "curl -sS -m %d -o '%s' '%s' >/dev/null 2>&1; echo $?",
    timeout, out:gsub("'", ""), url:gsub("'", ""))
  local p = io.popen(cmd)
  local code = p and (p:read("*l") or "1") or "1"
  if p then p:close() end
  if tostring(code):match("^0") then
    local f = io.open(out, "rb")
    local body = f and (f:read("*a") or "") or ""
    if f then f:close() end
    return true, body
  end
  return false, "http_fail:" .. tostring(code)
end

--- 简易 HTTP POST（body 为字符串；经 curl 兜底）
function M.httpPost(url, body, timeout, headers)
  timeout = tonumber(timeout) or M._timeout or 8
  url = tostring(url or "")
  body = tostring(body or "")
  if url == "" then return false, "empty_url" end
  if defined("pyCall") then
    local ok, res = pyCall("ziyan_net", "http_post", {
      url = url, body = body, timeout = timeout, headers = headers,
    })
    if ok then return true, res end
  end
  local out = tmpPath(".zy_http_post_out.txt")
  local tmp = tmpPath(".zy_http_post_body.txt")
  local bf = io.open(tmp, "wb")
  if bf then bf:write(body); bf:close() end
  local hdr = ""
  if type(headers) == "table" then
    for k, v in pairs(headers) do
      hdr = hdr .. string.format(" -H '%s: %s'", tostring(k):gsub("'", ""), tostring(v):gsub("'", ""))
    end
  end
  local cmd = string.format(
    "curl -sS -m %d -X POST%s --data-binary @'%s' -o '%s' '%s' >/dev/null 2>&1; echo $?",
    timeout, hdr, tmp:gsub("'", ""), out:gsub("'", ""), url:gsub("'", ""))
  local p = io.popen(cmd)
  local code = p and (p:read("*l") or "1") or "1"
  if p then p:close() end
  if tostring(code):match("^0") then
    local f = io.open(out, "rb")
    local resp = f and (f:read("*a") or "") or ""
    if f then f:close() end
    return true, resp
  end
  return false, "http_post_fail:" .. tostring(code)
end

--- 下载到本地路径
function M.download(url, dest, timeout)
  timeout = tonumber(timeout) or M._timeout or 8
  url, dest = tostring(url or ""), tostring(dest or "")
  if url == "" or dest == "" then return false, "empty" end
  local cmd = string.format(
    "curl -sS -m %d -o '%s' '%s' >/dev/null 2>&1; echo $?",
    timeout, dest:gsub("'", ""), url:gsub("'", ""))
  local p = io.popen(cmd)
  local code = p and (p:read("*l") or "1") or "1"
  if p then p:close() end
  if tostring(code):match("^0") then return true, dest end
  return false, "download_fail:" .. tostring(code)
end

--- 本机 IP（经引擎 getNetIP / ifconfig 兜底）
function M.netIP()
  if defined("getNetIP") then
    local ip = getNetIP()
    if ip and ip ~= "" then return ip end
  end
  if defined("NetIp") then
    local ip = NetIp()
    if ip and ip ~= "" then return ip end
  end
  local p = io.popen("ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null")
  if p then
    local ip = (p:read("*l") or ""):gsub("%s+$", "")
    p:close()
    if #ip > 0 then return ip end
  end
  return ""
end

--- Lua 表 ↔ JSON（自研封装 lua/json.lua；手册 Network.jsonEncode/Decode）
function M.jsonEncode(tbl)
  local ok, json = pcall(require, "json")
  if not ok or type(json) ~= "table" or type(json.encode) ~= "function" then
    return nil, "no_json"
  end
  local eok, out = pcall(json.encode, tbl)
  if not eok then return nil, tostring(out) end
  return out
end

function M.jsonDecode(str)
  local ok, json = pcall(require, "json")
  if not ok or type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil, "no_json"
  end
  local dok, out = pcall(json.decode, tostring(str or ""))
  if not dok then return nil, tostring(out) end
  return out
end

--- 网络时间（秒）；失败回退 os.time()
function M.netTime()
  if defined("getNetTime") then
    local t = getNetTime()
    if tonumber(t) then return tonumber(t) end
  end
  if defined("NetTime") then
    local t = NetTime()
    if tonumber(t) then return tonumber(t) end
  end
  local ok, body = M.httpGet("http://worldtimeapi.org/api/ip", 5)
  if ok and type(body) == "string" then
    local unix = body:match('"unixtime"%s*:%s*(%d+)')
    if unix then return tonumber(unix) end
  end
  return os.time()
end

return M
