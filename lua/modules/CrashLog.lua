--[[ CrashLog — 结构化崩溃/告警日志（终稿 P1）
  写入 $(ZIYAN_VAR)/.ziyan_crash_log.jsonl
]]

local M = { name = "CrashLog", version = "1.0.0" }

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  return io.open("/var/jb/usr/lib/ziyan/var", "r") and "/var/jb/usr/lib/ziyan/var"
      or "/usr/lib/ziyan/var"
end

function M.path()
  return var_dir() .. "/.ziyan_crash_log.jsonl"
end

function M.write(err_type, detail, extra)
  local rss = 0
  local fstatus = io.open("/proc/self/status", "r")
  if fstatus then
    local body = fstatus:read("*a") or ""
    fstatus:close()
    local kb = body:match("VmRSS:%s*(%d+)")
    if kb then rss = math.floor(tonumber(kb) / 1024) end
  end
  local loop = 0
  if _G.SafeExecutor and _G.SafeExecutor.state then
    loop = tonumber(_G.SafeExecutor.state.loop_count) or 0
  elseif _G.HealthMonitor then
    loop = tonumber(_G.HealthMonitor.loop_count) or 0
  end
  local line = string.format(
    '{"ts":%d,"loop":%d,"type":%q,"detail":%q,"rss":%d,"extra":%q}\n',
    os.time(), loop, tostring(err_type or "unknown"),
    tostring(detail or ""):sub(1, 240), rss,
    tostring(extra or ""):sub(1, 120))
  pcall(function()
    local f = io.open(M.path(), "a")
    if f then f:write(line); f:close() end
  end)
end

function M.install()
  _G.CrashLog = M
  _G.__ZIYAN_CRASH_LOG = M.version
  return M
end

return M
