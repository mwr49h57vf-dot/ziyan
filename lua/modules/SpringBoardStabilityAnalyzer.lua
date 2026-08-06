--[[ Zy.SpringBoardStabilityAnalyzer — SB 重启专项门面（7.6.3-R2）
  主机：tools/sb_stability/analyze.sh → logs/sb_restart/
]]
local M = { name = "SpringBoardStabilityAnalyzer", version = "1.0.0" }

function M.hint()
  return {
    metrics = {
      "cpu", "rss", "vsz", "threads", "lua_loops",
      "screenshots", "image_buffers", "ocr", "findColor",
      "findMultiColor", "exceptions",
    },
    logs = "logs/sb_restart/",
  }
end

return M
