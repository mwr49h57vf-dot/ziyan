--[[ CacheHealth — keepScreen 命中/延迟观测
  读 .ziyan_color_perf / .ziyan_keep_policy；异常写 .ziyan_cache_health
]]
local M = { name = "CacheHealth", version = "1.0.0" }

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local _hits, _miss, _slow = 0, 0, 0
local _last_report = 0

function M.note(find_ms, keep)
  find_ms = tonumber(find_ms) or 0
  if keep then _hits = _hits + 1 else _miss = _miss + 1 end
  if find_ms > 100 then _slow = _slow + 1 end
  local now = os.time()
  if now - _last_report >= 10 then
    _last_report = now
    local total = math.max(1, _hits + _miss)
    local line = string.format(
      "ts=%d hits=%d miss=%d slow=%d hit_rate=%.2f\n",
      now, _hits, _miss, _slow, _hits / total)
    local f = io.open(var_dir() .. "/.ziyan_cache_health", "w")
    if f then f:write(line); f:close() end
  end
end

function M.install()
  -- 被动：HealthMonitor / cv 可调用 note；此处仅挂全局
  _G.ZiYanCacheHealth = M
  return true
end

return M
