-- Smoke entry. Observe only. Never writes .ziyan_stop.
function main()
  local roots = {
    "/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua",
    "/var/jb/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua",
  }
  local runtime
  for _, p in ipairs(roots) do
    local ok, mod = pcall(dofile, p)
    if ok and type(mod) == "table" and mod.run_observe then
      runtime = mod
      break
    end
  end
  if not runtime then
    error("agent_runtime missing")
  end
  local s = runtime.run_observe({
    profile_id = "agent_smoke",
    bundle_id = "com.ziyan.ziyan",
    display_name = "AgentSmoke",
    game_name = "子砚",
  })
  if s.state ~= "STOPPED" and s.state ~= "PAUSED_SAFE" then
    error("agent_smoke state=" .. tostring(s.state))
  end
end
