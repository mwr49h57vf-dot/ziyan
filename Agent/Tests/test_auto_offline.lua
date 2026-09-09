-- Offline auto contract: observe, identify, verify, then tap once without learning.
local runtime = assert(dofile("Agent/Core/agent_runtime.lua"), "runtime missing")
local original_open = io.open
local original_toast = _G.toast
local original_safe_action = runtime.run_safe_action
local original_init = _G.init
local original_get_screen_size = _G.getScreenSize
local original_tap = _G.tap
local writes = {}
local front_reads = 0
local init_calls = 0
local tap_calls = 0
local tap_x
local tap_y

io.open = function(path, mode)
  if mode == "w" then
    local parts = {}
    return {
      write = function(_, body) parts[#parts + 1] = body end,
      close = function() writes[path] = table.concat(parts) end,
    }
  end
  return original_open(path, mode)
end

runtime.front_bid = function()
  front_reads = front_reads + 1
  return "com.ziyan.ziyan"
end
runtime.frame_seq = function() return 7 end
_G.init = function(orient)
  assert(orient == 0, tostring(orient))
  init_calls = init_calls + 1
end
_G.getScreenSize = function() return 1000, 2000 end
_G.tap = function(x, y)
  tap_calls = tap_calls + 1
  tap_x, tap_y = x, y
end
_G.toast = function() error("auto must not toast") end
runtime.run_safe_action = function() error("dispatch(auto) entered safe_action") end

local profile = {
  profile_id = "agent_default_observe",
  bundle_id = "com.ziyan.ziyan",
  display_name = "子砚",
}
local done = runtime.dispatch("auto", profile)
assert(done.state == "STOPPED", done.state)
assert(done.stop_reason == "auto_hid_ziyan_done", done.stop_reason)
assert(front_reads >= 5, tostring(front_reads))
assert(init_calls == 1, tostring(init_calls))
assert(tap_calls == 1, tostring(tap_calls))
assert(tap_x == 500, tostring(tap_x))
assert(tap_y == 160, tostring(tap_y))

local run_body
for path, body in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
  if path:match("/运行记录/ags_[A-Za-z0-9_]+%.txt$") then
    run_body = body
  end
end
assert(run_body, "auto run record missing")
for _, field in ipairs({
  "mode=auto",
  "front_bid=com.ziyan.ziyan",
  "frame_seq=7",
  "observed=com.ziyan.ziyan",
  "identified=front_bid=com.ziyan.ziyan bundle_id=com.ziyan.ziyan frame_seq=7",
  "verified=com.ziyan.ziyan",
  "tapped=1",
  "tap_rx=0.50",
  "tap_ry=0.08",
  "stop_reason=auto_hid_ziyan_done",
}) do
  assert(run_body:find(field, 1, true), field .. "\n" .. run_body)
end
assert(not run_body:find("mode=safe_action", 1, true), run_body)
assert(not run_body:find("mode=auto_delegate_app", 1, true), run_body)
assert(not run_body:find("auto_cycle_done", 1, true), run_body)

writes = {}
tap_calls = 0
local no_profile = runtime.dispatch("auto", {})
assert(no_profile.state == "PAUSED_SAFE", no_profile.state)
assert(no_profile.stop_reason == "no_profile", no_profile.stop_reason)
assert(tap_calls == 0, tostring(tap_calls))
for path, _ in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
  assert(not path:find("/运行记录/", 1, true), path)
end

writes = {}
runtime.front_bid = function() return "com.example.other" end
local mismatch = runtime.run_auto(profile)
assert(mismatch.state == "PAUSED_SAFE", mismatch.state)
assert(mismatch.stop_reason == "bundle_mismatch", mismatch.stop_reason)
assert(tap_calls == 0, tostring(tap_calls))
for path, _ in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
  assert(not path:find("/运行记录/", 1, true), path)
end

io.open = original_open
_G.toast = original_toast
runtime.run_safe_action = original_safe_action
_G.init = original_init
_G.getScreenSize = original_get_screen_size
_G.tap = original_tap
print("OFFLINE_TRUE_AUTO=PASS")
