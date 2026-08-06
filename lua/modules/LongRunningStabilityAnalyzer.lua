--[[ Zy.LongRunningStabilityAnalyzer — 长跑 SB 稳定性门面（7.6.3-R3）
  主机：tools/sb_stability/analyze.sh + ScreenBridge .ziyan_sb_mem_pulse
  日志：logs/sb_restart/
]]
local M = { name = "LongRunningStabilityAnalyzer", version = "1.0.0" }

function M.hint()
  return {
    pulse = ".ziyan_sb_mem_pulse",
    shutdown = ".ziyan_shutdown_log",
    logs = "logs/sb_restart/",
    rule = "universal_throttle_no_device_special_case",
  }
end

return M
