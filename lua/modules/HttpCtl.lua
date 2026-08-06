--[[ Zy.HttpCtl — F4 远程 HTTP 管理（自研薄封装，非触动模块）
  设计：本机 18080 状态面；启停走 .ziyan_* 文件 IPC（与硬锁兼容）
  内存风险：仅短连接读文件；禁止在 SB 内跑 HTTP
  用法：
    Zy.HttpCtl.status()           → table
    Zy.HttpCtl.requestStop()      → 写 stop 旗
    Zy.HttpCtl.requestUnlock()    → 写 unlock_req
  守护脚本：usr/lib/ziyan/bin/ziyan_httpctl_serve.sh（由 zydaemond 可选拉起）
]]
local M = { name = "HttpCtl", version = "1.0.0", port = 18080 }

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
    port = M.port,
    find_via = readTrim(v .. "/.ziyan_find_via"),
    framecap = readTrim(v .. "/.ziyan_framecap_alive"),
    daemon_v2 = readTrim(v .. "/.ziyan_daemon_v2"),
    zero_sb_full = readTrim(v .. "/.ziyan_zero_sb_full") ~= nil,
    color_perf = readTrim(v .. "/.ziyan_color_perf"),
  }
end

function M.requestStop()
  local v = varDir()
  local f = io.open(v .. "/.ziyan_stop", "w")
  if f then f:write("1\n"); f:close() end
  f = io.open(v .. "/.ziyan_user_stopped", "w")
  if f then f:write("1\n"); f:close() end
  return true
end

function M.requestUnlock()
  local v = varDir()
  local f = io.open(v .. "/.ziyan_unlock_req", "w")
  if not f then return false, "unlock_req_write" end
  f:write("1\n"); f:close()
  return true
end

--- 导出 JSON 一行（供 httpctl_serve 读取）
function M.exportJsonLine()
  local s = M.status()
  local parts = {
    string.format('"ok":%s', s.ok and "true" or "false"),
    string.format('"port":%d', s.port or 18080),
    string.format('"find_via":"%s"', tostring(s.find_via or "")),
    string.format('"daemon_v2":"%s"', tostring(s.daemon_v2 or "")),
  }
  return "{" .. table.concat(parts, ",") .. "}"
end

return M
