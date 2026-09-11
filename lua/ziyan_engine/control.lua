--[[ 控制：暂停 / 继续 / 停止（音量−菜单协同） ]]
local ZIYAN_VAR = _G.ZIYAN_VAR
if type(ZIYAN_VAR) ~= "string" or ZIYAN_VAR == "" then
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    ZIYAN_VAR = "/var/jb/usr/lib/ziyan/var"
  else
    ZIYAN_VAR = "/usr/lib/ziyan/var"
  end
end
local PAUSE_FLAG = ZIYAN_VAR .. "/.ziyan_paused"
local STOP_FLAG = ZIYAN_VAR .. "/.ziyan_stop"

local M = {}

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function native_sleep(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then
    return
  end
  -- 8-161-57：embed 优先 C usleep（禁 os.execute/busy-wait 拖死 framecap）
  if _G.ZIYAN_EMBED and type(_G.ziyan_embed_msleep) == "function" then
    pcall(_G.ziyan_embed_msleep, ms)
    return
  end
  local n = _G.__ZIYAN_NATIVE_MSLEEP
  if type(n) == "function" then
    n(ms)
    return
  end
  local bin = _G.ZIYAN_SLEEP or "sleep"
  local st = os.execute(string.format("'%s' %.3f", bin, ms / 1000.0))
  if st == true or st == 0 then
    return
  end
  local target = os.clock() + (ms / 1000.0)
  while os.clock() < target do
  end
end

-- 停止：绝不能 error()，否则触摸精灵/触动会弹「提示」堆栈窗
local function exit_on_stop()
  if not exists(STOP_FLAG) then return end
  pcall(os.remove, PAUSE_FLAG)
  -- 错误自动收集：强制停止是真实事件（幂等，一次停止只记一条）
  pcall(function()
    local er = _G.ErrorReporter
    if type(er) ~= "table" or type(er.on_stop) ~= "function" then return end
    local name = er.STOP_GUARD or ".ziyan_error_reporter_stop_done"
    local guard = ZIYAN_VAR .. "/" .. name
    local g = io.open(guard, "r")
    if g then g:close(); return end
    local w = io.open(guard, "w")
    if w then w:write(os.date("%Y-%m-%d %H:%M:%S") .. " stop\n"); w:close() end
    er.on_stop("user_stop", { phase = "control" })
  end)
  if type(scriptStop) == "function" then
    pcall(scriptStop)
  end
  -- 8-135：CLI lua5.3 必须真正退出；挂起会死进程占坑且音量−停不干净
  pcall(os.exit, 0)
  while true do
    native_sleep(500)
  end
end

local function wait_while_paused()
  while exists(PAUSE_FLAG) do
    exit_on_stop()
    -- 短轮询：点「继续」后更快醒（软暂停路径）
    native_sleep(50)
  end
  exit_on_stop()
end

function ziyan_pause_point()
  wait_while_paused()
end

function M.install()
  -- 无原生 mSleep（纯 lua5.3）时提供 shell sleep 兜底，再包装暂停检查点
  if type(mSleep) ~= "function" and not _G.__ZIYAN_NATIVE_MSLEEP then
    function mSleep(ms)
      ms = tonumber(ms) or 0
      if ms <= 0 then return end
      local bin = _G.ZIYAN_SLEEP or "sleep"
      os.execute(string.format("'%s' %.3f", bin, ms / 1000.0))
    end
  end
  if type(mSleep) == "function" and not _G.__ZIYAN_NATIVE_MSLEEP then
    _G.__ZIYAN_NATIVE_MSLEEP = mSleep
  end
  local native = _G.__ZIYAN_NATIVE_MSLEEP
  if type(native) ~= "function" then
    _G.__ZIYAN_wait_while_paused = wait_while_paused
    return M
  end
  local _last_session_pulse = 0
  function mSleep(ms)
    ms = tonumber(ms) or 0
    -- ★ HealthMonitor 注入：每轮 mSleep 自动触发健康检查（9 维度）
    -- 8-161-61：light 热路径禁 pulse（假阳性降频会把循环拖到数十秒）
    if ms > 0 and _G.HealthMonitor and not _G.__ZIYAN_SAFE_MSLEEP_ACTIVE
        and not _G.ZIYAN_LIGHT then
      pcall(_G.HealthMonitor.pulse)
    end
    if ms <= 0 then
      wait_while_paused()
      exit_on_stop()
      return
    end
    local left = ms
    while left > 0 do
      wait_while_paused()
      exit_on_stop()
      -- R8.1：每 20s 续写会话文件 + 触发 unlock（SB 重启后自动恢复）
      local now = os.time() or 0
      if (now - _last_session_pulse) >= 20 then
        _last_session_pulse = now
        if type(_G.__ZIYAN_mark_session) == "function" then
          pcall(_G.__ZIYAN_mark_session)
        end
      end
      local chunk = left > 150 and 150 or left
      native(chunk)
      left = left - chunk
      exit_on_stop()
    end
    wait_while_paused()
  end
  _G.__ZIYAN_MSLEEP_WRAPPED = true
  _G.__ZIYAN_wait_while_paused = wait_while_paused
  return M
end

return M
