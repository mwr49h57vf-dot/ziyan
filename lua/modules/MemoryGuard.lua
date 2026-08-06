--[[ MemoryGuard — 三级内存保护（终稿 P1）
  L1 keepScreen 释放 + GC
  L2 降频通知 SafeExecutor
  L3 写快照后主动退出（交守护重启）
]]

local M = { name = "MemoryGuard", version = "1.0.0" }

M.RSS_L1 = 80
M.RSS_L2 = 110
M.RSS_L3 = 140

local function rss_mb()
  if _G.HealthMonitor and type(_G.HealthMonitor.summary) == "function" then
    local s = _G.HealthMonitor.summary()
    if s and tonumber(s.rss) then return tonumber(s.rss) end
  end
  local f = io.open("/proc/self/status", "r")
  if not f then return 0 end
  local body = f:read("*a") or ""
  f:close()
  local kb = body:match("VmRSS:%s*(%d+)")
  return kb and math.floor(tonumber(kb) / 1024) or 0
end

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  return io.open("/var/jb/usr/lib/ziyan/var", "r") and "/var/jb/usr/lib/ziyan/var"
      or "/usr/lib/ziyan/var"
end

function M.check()
  local rss = rss_mb()
  if rss <= 0 then return "ok", rss end
  if rss >= M.RSS_L3 then
    -- 8-161-99：L3 只释帧+GC，禁止 os.exit（业务未 lua_exit 不得停）
    pcall(function()
      local f = io.open(var_dir() .. "/.ziyan_health_snapshot.json", "w")
      if f then
        f:write(string.format('{"ts":%d,"reason":"memory_guard_l3_no_exit","rss":%d}\n', os.time(), rss))
        f:close()
      end
    end)
    if type(_G.keepScreen) == "function" then pcall(_G.keepScreen, false) end
    collectgarbage("collect")
    if _G.SafeExecutor and _G.SafeExecutor.state then
      _G.SafeExecutor.state.degraded = true
    end
    return "throttle", rss
  elseif rss >= M.RSS_L2 then
    if type(_G.keepScreen) == "function" then pcall(_G.keepScreen, false) end
    collectgarbage("collect")
    if _G.SafeExecutor and _G.SafeExecutor.state then
      _G.SafeExecutor.state.degraded = true
      _G.SafeExecutor.state.cycle_ms = math.max(_G.SafeExecutor.state.cycle_ms or 500, 2000)
    end
    return "throttle", rss
  elseif rss >= M.RSS_L1 then
    if type(_G.keepScreen) == "function" then pcall(_G.keepScreen, false) end
    collectgarbage("collect")
    return "gc", rss
  end
  return "ok", rss
end

function M.install()
  _G.MemoryGuard = M
  _G.__ZIYAN_MEMORY_GUARD = M.version
  return M
end

return M
