--[[ Zy.FrameHook — F11 帧回调 Hook 控制面（自研薄封装）
  设计：读写 .ziyan_frame_hook_* 旗；启用走既有 ZiYanFrameHook.m
  默认关闭（需 enable）；热路径勿每帧 Lua 轮询
]]
local M = { name = "FrameHook", version = "1.0.0" }

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

function M.enable()
  local v = varDir()
  os.remove(v .. "/.ziyan_frame_hook_off")
  local f = io.open(v .. "/.ziyan_frame_hook_enable", "w")
  if not f then return false end
  f:write("1\n"); f:close()
  return true
end

function M.disable()
  local v = varDir()
  os.remove(v .. "/.ziyan_frame_hook_enable")
  local f = io.open(v .. "/.ziyan_frame_hook_off", "w")
  if f then f:write("1\n"); f:close() end
  return true
end

function M.status()
  local v = varDir()
  return {
    ok = true,
    enable = readTrim(v .. "/.ziyan_frame_hook_enable") ~= nil,
    off = readTrim(v .. "/.ziyan_frame_hook_off") ~= nil,
    alive = readTrim(v .. "/.ziyan_frame_hook_alive"),
  }
end

return M
