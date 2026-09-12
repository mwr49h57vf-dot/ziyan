-- Safe ZiYan migration of 系统工具/ZYXiTongGongJu.lua.
-- The source's endless toast loop is reduced to a bounded lifecycle sample:
-- no shell execution, proxy/network access, credentials, or retained buffers.

local Zy = require("modules.init")
local Log = Zy.Log
local Timer = Zy.Timer

local loops = tonumber(os.getenv("ZIYAN_SAMPLE_LOOPS")) or 5
local result_path = os.getenv("ZIYAN_SAMPLE_RESULT")

for index = 1, math.max(0, math.min(loops, 20)) do
  Log.write(string.format("system_tool_sample step=%d", index))
  -- 3000 ms preserves source pacing and avoids a high-frequency toast loop.
  Timer.mSleep(3000)
end

if result_path and result_path ~= "" then
  local file = assert(io.open(result_path, "w"))
  file:write("status=completed\nsample=ziyan_system_tool_sample\n")
  file:close()
end
