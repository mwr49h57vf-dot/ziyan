--[[ Zy.StabilityAnalyzer — 模块门面（阶段7.6.2-R4）]]
local M = { name = "StabilityAnalyzer", version = "1.0.0" }

function M.pulse(extra)
  local S = _G.ZiYanStability
  if S and S.pulse then return S.pulse(extra) end
end

function M.snapshot()
  local S = _G.ZiYanStability
  if S and S.snapshot_table then return S.snapshot_table() end
  return {}
end

return M
