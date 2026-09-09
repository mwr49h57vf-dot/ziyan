-- Offline: learn records one observation only after front and frame precheck.
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
local original_open = io.open
local files = {}
io.open = function(path, mode)
  if mode == "w" then
    local parts = {}
    return {
      write = function(_, body) parts[#parts + 1] = body end,
      close = function() files[path] = table.concat(parts) end,
    }
  end
  return original_open(path, mode)
end
runtime.front_bid = function() return "com.example.game" end
runtime.frame_seq = function() return 7 end
local s = runtime.run_learn({
  profile_id = "offline", bundle_id = "com.example.game",
  display_name = "Offline",
})
assert(s.state == "STOPPED", s.state)
assert(s.stop_reason == "learn_recorded", s.stop_reason)
local learn_path, learn_body, run_body, session_body
for path, body in pairs(files) do
  if path:match("/学习数据/ags_[A-Za-z0-9_]+%.txt$") then
    learn_path, learn_body = path, body
  elseif path:match("/运行记录/ags_[A-Za-z0-9_]+%.txt$") then
    run_body = body
  elseif path:match("%.ziyan_agent_session$") then
    session_body = body
  end
end
assert(learn_path, "learning file missing")
assert(learn_body:find("front_bid=com.example.game\n", 1, true), learn_body)
assert(learn_body:find("frame_seq=7\n", 1, true), learn_body)
assert(learn_body:find("bundle_id=com.example.game\n", 1, true), learn_body)
assert(learn_body:find("profile_id=offline\n", 1, true), learn_body)
assert(learn_body:match("ts=%d+\n"), learn_body)
assert(run_body and run_body:find("mode=learn", 1, true), run_body)
assert(session_body == "state=STOPPED\nui_state=未运行\nactive=0\n", session_body)

files = {}
runtime.front_bid = function() return "payment" end
local paused = runtime.run_learn({
  profile_id = "offline", bundle_id = "com.example.game",
  display_name = "Offline",
})
io.open = original_open
assert(paused.state == "PAUSED_SAFE", paused.state)
for path, _ in pairs(files) do
  assert(not path:find("/学习数据/", 1, true), path)
end
print("OFFLINE_TRUE_LEARN=PASS")
