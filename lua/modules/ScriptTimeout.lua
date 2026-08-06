--[[ ScriptTimeout — 过程稿/稳定性：循环卡死保险丝
  用法：install() 后对长循环生效；默认 30s 无 yield 则记日志并抛错
  内存风险：仅 hook 计数，不分配大缓冲
]]
local M = { name = "ScriptTimeout", version = "1.0.0" }

local LIMIT_SEC = 30
local _armed = false
local _deadline = 0
local _last = 0

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function pulse()
  _last = os.clock()
  if _armed then
    _deadline = _last + LIMIT_SEC
  end
end

local function check()
  if not _armed then return end
  local now = os.clock()
  if now > _deadline then
    local f = io.open(var_dir() .. "/.ziyan_script_timeout", "w")
    if f then
      f:write(string.format("ts=%.0f limit=%d\n", os.time(), LIMIT_SEC))
      f:close()
    end
    _armed = false
    error("ZiYan ScriptTimeout: loop exceeded " .. LIMIT_SEC .. "s without yield", 0)
  end
end

function M.arm(sec)
  LIMIT_SEC = tonumber(sec) or 30
  _armed = true
  pulse()
end

function M.disarm()
  _armed = false
end

function M.install()
  -- 挂到 mSleep：每次 sleep 视为 yield
  local old = _G.mSleep
  if type(old) == "function" and not _G.__ZIYAN_SCRIPT_TIMEOUT then
    _G.__ZIYAN_SCRIPT_TIMEOUT = true
    _G.mSleep = function(ms)
      pulse()
      check()
      return old(ms)
    end
  end
  M.arm(30)
  return true
end

return M
