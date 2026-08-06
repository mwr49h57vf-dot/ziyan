--[[ Zy.Timer — 延时/超时/时钟（自研；mSleep 经引擎 time 模块）
  注意：长 sleep 会阻塞脚本协程；循环内宜配合 Zy.Script.tick 心跳。
]]
local M = { name = "Timer", version = "1.0.0", _default_timeout = 30 }

local function defined(n) return type(_G[n]) == "function" end

local function sleep_ms(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then return true end
  if defined("mSleep") then
    return not not mSleep(ms)
  end
  if defined("sleep") then
    return not not sleep(ms / 1000)
  end
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < ms do end
  return true
end

--- 毫秒延时
function M.sleepMs(ms)
  return sleep_ms(ms)
end

--- 秒延时
function M.sleep(sec)
  return sleep_ms((tonumber(sec) or 0) * 1000)
end

--- 别名：与 TS mSleep 对齐
function M.mSleep(ms)
  return sleep_ms(ms)
end

--- 当前 Unix 时间戳（秒）
function M.now()
  return os.time()
end

--- 高精度时钟（秒，浮点）
function M.clock()
  return os.clock()
end

--- 格式化本地时间
function M.format(fmt, ts)
  fmt = fmt or "%Y-%m-%d %H:%M:%S"
  ts = tonumber(ts) or os.time()
  return os.date(fmt, ts)
end

--- 设置全局超时秒数（脚本会话级；仅 Lua 侧记录）
function M.setGlobalTimeout(sec)
  sec = tonumber(sec) or M._default_timeout
  M._default_timeout = math.max(1, sec)
  _G.__ZIYAN_GLOBAL_TIMEOUT = M._default_timeout
  return M._default_timeout
end

function M.globalTimeout()
  return _G.__ZIYAN_GLOBAL_TIMEOUT or M._default_timeout
end

--- 在 timeout_ms 内轮询 cond_fn，间隔 interval_ms
function M.waitUntil(cond_fn, timeout_ms, interval_ms)
  if type(cond_fn) ~= "function" then return false, "no_cond" end
  timeout_ms = tonumber(timeout_ms) or 5000
  interval_ms = tonumber(interval_ms) or 200
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < timeout_ms do
    local ok, hit = pcall(cond_fn)
    if ok and hit then return true end
    sleep_ms(interval_ms)
  end
  return false, "timeout"
end

--- 网络时间（经 Device/引擎；失败回退本地）
function M.netTime()
  if defined("getNetTime") then
    local t = getNetTime()
    if tonumber(t) then return tonumber(t) end
  end
  if type(_G.Zy) == "table" and _G.Zy.Network and type(_G.Zy.Network.netTime) == "function" then
    local ok, t = pcall(_G.Zy.Network.netTime)
    if ok and tonumber(t) then return tonumber(t) end
  end
  return os.time()
end

return M
