-- Offline: chapter 27 must not use the 36s learn skeleton or single safe_action.
local roots = {
  "Agent/Core/agent_runtime.lua",
}
local runtime
for _, p in ipairs(roots) do
  local ok, mod = pcall(dofile, p)
  if ok and type(mod) == "table" then
    runtime = mod
    break
  end
end
assert(runtime, "runtime missing")
local s = runtime.run_learn({
  profile_id = "offline", bundle_id = "com.example.game",
  display_name = "Offline",
})
assert(s.stop_reason == "learn_owned_by_app", s.stop_reason)
local a = runtime.run_auto({
  profile_id = "offline", bundle_id = "com.example.game",
  display_name = "Offline",
})
assert(a.stop_reason == "auto_owned_by_app", a.stop_reason)
print("OFFLINE_LEARN_DELEGATE=PASS")
