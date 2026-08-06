--[[ Zy.ScreenWakeManager — 屏幕唤醒状态管控（7.6.3-R3）
  规则：仅脚本/项目活跃时允许自动解锁；空闲忽略 unlock_req。
  Oc 侧：ZiYanScreenBridge pollUnlock + startInSpringBoard。
]]
local M = { name = "ScreenWakeManager", version = "1.0.0" }

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

function M.log(event, extra)
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_wake_log", "a")
    if not f then return end
    f:write(string.format("ts=%d event=%s %s\n", os.time(), tostring(event), tostring(extra or "")))
    f:close()
  end)
end

function M.scriptStarted()
  M.log("script_started", "wake_enabled=1")
end

function M.scriptStopped()
  M.log("script_stopped", "wake_enabled=0")
end

return M
