-- Agent entry for ziyan_run.lua. Never writes .ziyan_stop.
function main()
  local roots = {
    "/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua",
    "/var/jb/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua",
  }
  local runtime
  for _, p in ipairs(roots) do
    local ok, mod = pcall(dofile, p)
    if ok and type(mod) == "table" and mod.dispatch then
      runtime = mod
      break
    end
  end
  if not runtime then
    error("agent_runtime missing")
  end
  local var = _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
  local mode = "observe"
  local f = io.open(var .. "/.ziyan_agent_req", "r")
  if f then
    local body = f:read("*a") or ""
    f:close()
    mode = body:match("mode=([^\n]+)") or mode
  end
  local s = runtime.dispatch(mode)
  if s.state ~= "STOPPED" and s.state ~= "PAUSED_SAFE" then
    error("agent_run state=" .. tostring(s.state))
  end
end
