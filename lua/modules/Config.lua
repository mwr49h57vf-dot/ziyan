--[[ Zy.Config — 脚本配置读写（JSON，对齐 ts.config 思想，非 plist 拷贝）]]
local C = require("modules._ctx")
local M = { name = "Config", version = "1.0.0", model = "JsonConfigStore" }

local function media()
  return "/private/var/mobile/Media/ZiYan"
end

local function default_path(name)
  name = tostring(name or "script"):gsub("[^%w_%-]", "_")
  return media() .. "/config/" .. name .. ".json"
end

local function ensure_dir()
  pcall(function()
    os.execute(string.format('mkdir -p "%s/config"', media()))
  end)
end

--- 配置文件路径
function M.path(name)
  return default_path(name)
end

--- 读取 JSON 配置；失败返回 default 或 {}
function M.load(name, default)
  ensure_dir()
  local path = default_path(name)
  local Zy = _G.Zy
  local body = nil
  if Zy and Zy.File and Zy.File.read then
    body = Zy.File.read(path)
  else
    local f = io.open(path, "r")
    if f then body = f:read("*a"); f:close() end
  end
  if not body or body == "" then
    return default or {}
  end
  -- 极简 JSON：优先 cjson / dkjson / 引擎 json
  if type(json) == "table" and type(json.decode) == "function" then
    local ok, t = pcall(json.decode, body)
    if ok and type(t) == "table" then return t end
  end
  if type(cjson) == "table" and type(cjson.decode) == "function" then
    local ok, t = pcall(cjson.decode, body)
    if ok and type(t) == "table" then return t end
  end
  -- 兜底：返回 raw 包装
  return { __raw = body }
end

--- 保存配置表为 JSON
function M.save(name, tbl)
  ensure_dir()
  tbl = tbl or {}
  local path = default_path(name)
  local body
  if type(json) == "table" and type(json.encode) == "function" then
    local ok, s = pcall(json.encode, tbl)
    if ok then body = s end
  end
  if not body and type(cjson) == "table" and type(cjson.encode) == "function" then
    local ok, s = pcall(cjson.encode, tbl)
    if ok then body = s end
  end
  if not body then
    -- 极简键值序列化（仅扁平 string/number/boolean）
    local parts = { "{" }
    local first = true
    for k, v in pairs(tbl) do
      if type(k) == "string" and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
        if not first then parts[#parts + 1] = "," end
        first = false
        if type(v) == "string" then
          parts[#parts + 1] = string.format('%q:%q', k, v)
        else
          parts[#parts + 1] = string.format('%q:%s', k, tostring(v))
        end
      end
    end
    parts[#parts + 1] = "}"
    body = table.concat(parts)
  end
  local Zy = _G.Zy
  if Zy and Zy.File and Zy.File.write then
    Zy.File.write(path, body)
  else
    local f = io.open(path, "w")
    if f then f:write(body); f:close() end
  end
  return path
end

--- 读单个键
function M.get(name, key, default)
  local t = M.load(name, {})
  if t[key] ~= nil then return t[key] end
  return default
end

--- 写单个键并保存
function M.set(name, key, value)
  local t = M.load(name, {})
  t[key] = value
  M.save(name, t)
  return value
end

return M
