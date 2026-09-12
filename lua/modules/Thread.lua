--[[ Zy.Thread — 协作式线程（单 Lua 状态机；非 OS 真线程）
  Division2 Wave4：对齐 TS thread.* 契约名；禁止阻塞 SB 主线程（本模块仅在 lua 进程）。
  风险：create 内死循环无 mSleep/wait 会饿死调度；勿在回调里狂截屏。
]]
local M = { name = "Thread", version = "1.0.0" }

local _next = 1
local _jobs = {} -- id -> { co, alive, err }
local _timeouts = {} -- id -> { at, fn, alive }
local _tid = 1

local function sleep_ms(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then return end
  if type(_G.mSleep) == "function" then
    mSleep(ms)
  else
    local n = os.clock() + ms / 1000
    while os.clock() < n do end
  end
end

local function now_ms()
  return (os.time() * 1000) + math.floor((os.clock() % 1) * 1000)
end

function M._pump_timeouts()
  local t = now_ms()
  for id, to in pairs(_timeouts) do
    if to.alive and t >= to.at then
      to.alive = false
      pcall(to.fn)
    end
  end
end

function M._resume(id)
  local j = _jobs[id]
  if not j or not j.alive then return false end
  local co = j.co
  if coroutine.status(co) == "dead" then
    j.alive = false
    return false
  end
  local ok, a = coroutine.resume(co)
  if not ok then
    j.alive = false
    j.err = tostring(a)
    return false
  end
  if coroutine.status(co) == "dead" then
    j.alive = false
  elseif type(a) == "number" and a > 0 then
    sleep_ms(a)
  end
  return j.alive
end

--- 创建协作线程；返回 id
function M.create(fn)
  if type(fn) ~= "function" then return nil, "need_function" end
  local id = _next
  _next = _next + 1
  local co = coroutine.create(function()
    fn()
  end)
  _jobs[id] = { co = co, alive = true, err = nil }
  M._resume(id)
  return id
end

function M.createSubThread(fn)
  return M.create(fn)
end

--- 当前协作上下文等待；主线程则 mSleep
function M.wait(ms)
  ms = tonumber(ms) or 0
  local co, is_main = coroutine.running()
  if co and not is_main then
    return coroutine.yield(ms)
  end
  sleep_ms(ms)
  M._pump_timeouts()
  return true
end

function M.setTimeout(ms, fn)
  if type(fn) ~= "function" then return nil, "need_function" end
  local id = _tid
  _tid = _tid + 1
  _timeouts[id] = { at = now_ms() + (tonumber(ms) or 0), fn = fn, alive = true }
  return id
end

function M.clearTimeout(id)
  id = tonumber(id)
  if id and _timeouts[id] then
    _timeouts[id].alive = false
    return true
  end
  return false
end

function M.stop(id)
  id = tonumber(id)
  if id and _jobs[id] then
    _jobs[id].alive = false
    return true
  end
  return false
end

--- 推进所有未结束协作线程 + 超时回调（带步数上限防死循环）
function M.waitAllThreadExit(max_steps)
  max_steps = tonumber(max_steps) or 10000
  for _ = 1, max_steps do
    M._pump_timeouts()
    local any = false
    for id, j in pairs(_jobs) do
      if j.alive then
        any = true
        M._resume(id)
      end
    end
    if not any then return true end
    sleep_ms(10)
  end
  return false, "timeout_steps"
end

return M
