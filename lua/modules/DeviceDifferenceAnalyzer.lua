--[[ Zy.DeviceDifferenceAnalyzer — 双机差异分析门面（阶段7.6.3-R2）
  主机采集：tools/device_difference/analyze.sh → device_difference_report.md
  禁止：学习设备部署；单设备特判坐标；改用户脚本
]]
local M = { name = "DeviceDifferenceAnalyzer", version = "1.0.0" }

function M.compare_hint()
  return {
    devices = { "192.168.31.166", "192.168.31.53" },
    fields = {
      "screen_size", "native_pixels", "logic_size", "scale",
      "orientation", "capture_buffer", "coordinate_transform",
      "touch_injection", "memory", "ios_version",
    },
    report = "device_difference_report.md",
  }
end

return M
