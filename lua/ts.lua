-- Offline-only compatibility module for the smallest legacy Lua contract.
local json = require("json")

local M = {
  name = "ts",
  version = "offline-1.1.0",
  mode = "offline",
}

local ALLOWLIST_ROOT = "/private/var/mobile/Media/ZiYan/ZYCV/config"
local LEGACY_PREFIX = "/private/var/mobile/Media/TouchSprite/config/"
local ALLOWED_ZIYAN_VARS = {
  ["/usr/lib/ziyan/var"] = true,
  ["/var/jb/usr/lib/ziyan/var"] = true,
}

local store = {}
local live_handles = {}
local next_handle_id = 0

local function validate_config_root()
  local configured = rawget(_G, "ZIYAN_COMPAT_CONFIG_DIR")
  if configured ~= nil and configured ~= "" and configured ~= ALLOWLIST_ROOT then
    return false, "invalid_config_root"
  end
  local env_configured = os.getenv("ZIYAN_COMPAT_CONFIG_DIR")
  if env_configured ~= nil and env_configured ~= ""
      and env_configured ~= ALLOWLIST_ROOT then
    return false, "invalid_config_root"
  end

  local ziyan_var = rawget(_G, "ZIYAN_VAR")
  if ziyan_var ~= nil and ziyan_var ~= "" and not ALLOWED_ZIYAN_VARS[ziyan_var] then
    return false, "invalid_config_root"
  end
  local env_ziyan_var = os.getenv("ZIYAN_VAR")
  if env_ziyan_var ~= nil and env_ziyan_var ~= ""
      and not ALLOWED_ZIYAN_VARS[env_ziyan_var] then
    return false, "invalid_config_root"
  end
  return true
end

local function canonical_name(name)
  if type(name) ~= "string" or name == ""
      or name:find("[%z\r\n]") then
    return nil, "invalid_config_name"
  end
  if name:sub(1, 1) == "/" then
    if name:sub(1, #LEGACY_PREFIX) ~= LEGACY_PREFIX then
      return nil, "invalid_config_path"
    end
    local leaf = name:sub(#LEGACY_PREFIX + 1)
    if leaf == "" or leaf:find("[/\\]") or leaf:find("%.%.")
        or not leaf:match("^[%w_.%-]+%.json$") then
      return nil, "invalid_config_path"
    end
    return "legacy_" .. leaf:gsub("%.json$", "")
  end
  if name:find("[/\\]") or name:find("%.%.")
      or not name:match("^[%w_.%-]+$") then
    return nil, "invalid_config_name"
  end
  return name
end

local function config_key(key)
  if type(key) ~= "string" or key == "" or key:find("[%z\r\n/]") then
    return nil, "invalid_config_key"
  end
  return key
end

local function clone(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[clone(k, seen)] = clone(v, seen)
  end
  return out
end

local function is_handle(value)
  return type(value) == "table" and value.__ziyan_ts_config_handle == true
end

local function live_handle(handle)
  if not is_handle(handle) then return false, "invalid_handle" end
  if not live_handles[handle] or handle.state ~= "open" then
    return false, "closed_handle"
  end
  return true
end

local config = {
  allowlisted_root = ALLOWLIST_ROOT,
}

function config.root()
  return ALLOWLIST_ROOT
end

function config.path(name)
  local ok, reason = validate_config_root()
  if not ok then return false, reason end
  local namespace, name_reason = canonical_name(name)
  if not namespace then return false, name_reason end
  return ALLOWLIST_ROOT .. "/" .. namespace .. ".json"
end

function config.open(name)
  local ok, reason = validate_config_root()
  if not ok then return false, reason end
  local namespace, name_reason = canonical_name(name or "default")
  if not namespace then return false, name_reason end
  next_handle_id = next_handle_id + 1
  local handle = {
    __ziyan_ts_config_handle = true,
    id = next_handle_id,
    namespace = namespace,
    state = "open",
    data = clone(store[namespace] or {}),
  }
  live_handles[handle] = true
  return handle
end

local function handle_get(handle, key, default)
  local ok, reason = live_handle(handle)
  if not ok then return nil, reason end
  local valid_key, key_reason = config_key(key)
  if not valid_key then return nil, key_reason end
  if handle.data[valid_key] ~= nil then
    return clone(handle.data[valid_key])
  end
  return default
end

local function handle_save(handle, key, value)
  local ok, reason = live_handle(handle)
  if not ok then return false, reason end
  if key == nil then
    store[handle.namespace] = clone(handle.data)
    return true
  end
  if type(key) == "table" and value == nil then
    for item_key, item_value in pairs(key) do
      local valid_key, key_reason = config_key(item_key)
      if not valid_key then return false, key_reason end
      handle.data[valid_key] = clone(item_value)
    end
  else
    local valid_key, key_reason = config_key(key)
    if not valid_key then return false, key_reason end
    handle.data[valid_key] = clone(value)
  end
  store[handle.namespace] = clone(handle.data)
  return true
end

local function handle_delete(handle, key)
  local ok, reason = live_handle(handle)
  if not ok then return false, reason end
  if key == nil then
    store[handle.namespace] = nil
    handle.data = {}
    return true
  end
  local valid_key, key_reason = config_key(key)
  if not valid_key then return false, key_reason end
  handle.data[valid_key] = nil
  store[handle.namespace] = clone(handle.data)
  return true
end

function config.get(target, key, default)
  if is_handle(target) then
    return handle_get(target, key, default)
  end
  local handle, reason = config.open(target)
  if handle == false then return nil, reason end
  local value, get_reason = handle_get(handle, key, default)
  config.close(handle)
  return value, get_reason
end

function config.save(target, key, value)
  if is_handle(target) then
    return handle_save(target, key, value)
  end
  local handle, reason = config.open(target)
  if handle == false then return false, reason end
  local ok, save_reason = handle_save(handle, key, value)
  config.close(handle)
  return ok, save_reason
end

function config.delete(target, key)
  if is_handle(target) then
    return handle_delete(target, key)
  end
  local handle, reason = config.open(target)
  if handle == false then return false, reason end
  local ok, delete_reason = handle_delete(handle, key)
  config.close(handle)
  return ok, delete_reason
end

function config.close(handle)
  local ok, reason = live_handle(handle)
  if not ok then return false, reason end
  store[handle.namespace] = clone(handle.data)
  live_handles[handle] = nil
  handle.state = "closed"
  return true
end

function config.load(name, default)
  local handle, reason = config.open(name)
  if handle == false then return default or {}, reason end
  local data = clone(handle.data)
  config.close(handle)
  if next(data) == nil and default ~= nil then return default end
  return data
end

config.read = config.load
config.write = config.save

function config.set(name, key, value)
  local ok, reason = config.save(name, key, value)
  if not ok then return nil, reason end
  return value
end

M.config = config

local ftp = {}
local function unsupported()
  return false, "unsupported:offline_ftp"
end

for _, name in ipairs({
  "init", "clean", "setTimeout", "upload", "download", "delete",
  "read", "list", "mkdir", "rmdir", "rename",
}) do
  ftp[name] = unsupported
end

M.ftp = ftp
_G.ts = M
return M
