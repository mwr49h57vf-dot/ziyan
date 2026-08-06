--[[ Zy.AppDump — F6 脱壳/IPA 流水线（自研薄封装，非触动）
  设计：文件 IPC 驱动 dump 请求；读 ZYCV/ANALYSIS 状态
  内存风险：仅写短旗/读摘要；禁止在 SB 热路径调用
  用法：
    Zy.AppDump.request(bundleId) → bool
    Zy.AppDump.status() → table
]]
local M = { name = "AppDump", version = "1.0.0" }

local function varDir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function mediaDir()
  return "/var/mobile/Media/ZiYan"
end

local function readTrim(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a") or ""
  f:close()
  return (s:gsub("%s+$", ""))
end

function M.request(bundleId)
  local v = varDir()
  local f = io.open(v .. "/.ziyan_dump_req", "w")
  if not f then return false, "dump_req_write" end
  f:write(tostring(bundleId or "com.apple.springboard") .. "\n")
  f:close()
  return true
end

function M.status()
  local v, m = varDir(), mediaDir()
  return {
    ok = true,
    pending = readTrim(v .. "/.ziyan_dump_req") ~= nil,
    last = readTrim(v .. "/.ziyan_dump_last") or readTrim(m .. "/ZYCV/.ziyan_dump_last"),
    analysis = readTrim(m .. "/ZYCV/ANALYSIS.md") ~= nil,
  }
end

return M
