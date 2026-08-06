--[[ Zy.AutoInject — F12 Mach-O / 注入状态面（自研薄封装）
  设计：读 inject gate / daemon / Filter 状态；写 open_app / inject_req
  禁止在本模块内做任意进程注入攻击面；仅产品自有包状态
]]
local M = { name = "AutoInject", version = "1.0.0" }

local function varDir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function readTrim(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a") or ""
  f:close()
  return (s:gsub("%s+$", ""))
end

function M.status()
  local v = varDir()
  return {
    ok = true,
    daemon_v2 = readTrim(v .. "/.ziyan_daemon_v2"),
    zero_sb_full = readTrim(v .. "/.ziyan_zero_sb_full") ~= nil,
    zero_sb_inject = readTrim(v .. "/.ziyan_zero_sb_inject") ~= nil,
    framecap = readTrim(v .. "/.ziyan_framecap_alive"),
    hooks = readTrim(v .. "/.ziyan_hooks_alive"),
  }
end

function M.requestOpenApp(bundleId)
  local v = varDir()
  local f = io.open(v .. "/.ziyan_open_app", "w")
  if not f then return false end
  f:write(tostring(bundleId or "com.ziyan.ziyan") .. "\n")
  f:close()
  return true
end

function M.export()
  local s = M.status()
  local v = varDir()
  local f = io.open(v .. "/.ziyan_autoinject", "w")
  if not f then return false end
  f:write(string.format(
    "daemon=%s\nzero_full=%s\nframecap=%s\n",
    tostring(s.daemon_v2 or ""), s.zero_sb_full and "1" or "0",
    tostring(s.framecap or "")))
  f:close()
  return true, s
end

return M
