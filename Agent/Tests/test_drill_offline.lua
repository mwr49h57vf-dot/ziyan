-- Offline drill contract: replay one learned observation and stop on marker.
_G.ZIYAN_VAR = "/tmp/ziyan_drill_offline_var"
local runtime = assert(dofile("Agent/Core/agent_runtime.lua"), "runtime missing")
local original_open = io.open
local original_remove = os.remove
local original_msleep = _G.mSleep
local writes = {}
local reads = {}
local stop_present = false
local learn_present = true
local learn_id_present = true
local removed_stop = false
local sleep_calls = 0
local learn_id = "ags_17886130846274"
local learn_id_body = learn_id .. "\n"
local learn_body = table.concat({
  "front_bid=com.ziyan.ziyan",
  "frame_seq=78114",
  "bundle_id=com.ziyan.ziyan",
  "profile_id=agent_default_observe",
  "ts=1788613084",
  "",
}, "\n")

local function read_handle(body)
  local line_end = body:find("\n", 1, true)
  local first_line = line_end and body:sub(1, line_end - 1) or body
  local rest = line_end and body:sub(line_end + 1) or ""
  local line_read = false
  return {
    read = function(_, mode)
      if mode == "*l" then
        if line_read then return nil end
        line_read = true
        return first_line
      end
      if line_read then return rest end
      line_read = true
      return body
    end,
    close = function() end,
  }
end

io.open = function(path, mode)
  if mode == "w" then
    local parts = {}
    return {
      write = function(_, body) parts[#parts + 1] = body end,
      close = function() writes[path] = table.concat(parts) end,
    }
  end
  if learn_id_present and path:match("/%.ziyan_drill_learn_id$") then
    return read_handle(learn_id_body)
  end
  if learn_present and path:match("/学习数据/" .. learn_id .. "%.txt$") then
    return read_handle(learn_body)
  end
  if path:match("/%.ziyan_agent_stop$") and stop_present then
    return read_handle("stop=1\n")
  end
  return original_open(path, mode)
end

os.remove = function(path)
  if path:match("/%.ziyan_agent_stop$") then
    removed_stop = true
    stop_present = false
  end
  return true
end

runtime.front_bid = function() return "com.ziyan.ziyan" end
runtime.frame_seq = function() return 78114 end
_G.ZIYAN_DRILL_LEARN_ID = "ags_17886131005180"
_G.mSleep = function(ms)
  assert(ms == 250, tostring(ms))
  sleep_calls = sleep_calls + 1
  if sleep_calls == 1 then
    stop_present = true
  end
end
local stopped = runtime.run_drill({
  profile_id = "agent_default_observe",
  bundle_id = "com.ziyan.ziyan",
  display_name = "子砚",
})
assert(stopped.state == "STOPPED", stopped.state)
assert(stopped.stop_reason == "agent_stop", stopped.stop_reason)
assert(sleep_calls == 1, tostring(sleep_calls))
assert(removed_stop, "stop marker was not cleared")
local run_body
for path, body in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
  if path:match("/运行记录/ags_[A-Za-z0-9_]+%.txt$") then
    run_body = body
  end
end
assert(run_body and run_body:find("learn_id=" .. learn_id, 1, true), run_body)
assert(run_body:find("front_bid=com.ziyan.ziyan", 1, true), run_body)
assert(run_body:find("frame_seq=78114", 1, true), run_body)
assert(run_body:find("mode=drill", 1, true), run_body)
assert(run_body:find("stop_reason=agent_stop", 1, true), run_body)
assert(not run_body:find("drill_timeout", 1, true), run_body)

writes = {}
learn_present = false
learn_id_present = true
stop_present = false
sleep_calls = 0
local missing = runtime.run_drill({
  profile_id = "agent_default_observe",
  bundle_id = "com.ziyan.ziyan",
})
assert(missing.state == "PAUSED_SAFE", missing.state)
assert(missing.stop_reason == "missing_learn", missing.stop_reason)
for path, _ in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
end

writes = {}
learn_id_present = false
learn_present = true
stop_present = false
sleep_calls = 0
local missing_id = runtime.run_drill({
  profile_id = "agent_default_observe",
  bundle_id = "com.ziyan.ziyan",
})
assert(missing_id.state == "PAUSED_SAFE", missing_id.state)
assert(missing_id.stop_reason == "missing_learn", missing_id.stop_reason)
for path, _ in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
end

writes = {}
learn_id_present = true
learn_id_body = learn_id .. "\nextra\n"
stop_present = false
sleep_calls = 0
local malformed_id = runtime.run_drill({
  profile_id = "agent_default_observe",
  bundle_id = "com.ziyan.ziyan",
})
assert(malformed_id.state == "PAUSED_SAFE", malformed_id.state)
assert(malformed_id.stop_reason == "missing_learn", malformed_id.stop_reason)
for path, _ in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
end

writes = {}
learn_present = true
learn_id_body = learn_id .. "\n"
stop_present = false
sleep_calls = 0
learn_body = learn_body:gsub("front_bid=com%.ziyan%.ziyan", "front_bid=com.example.other")
local learned_mismatch = runtime.run_drill({
  profile_id = "agent_default_observe",
  bundle_id = "com.ziyan.ziyan",
})
assert(learned_mismatch.state == "PAUSED_SAFE", learned_mismatch.state)
assert(learned_mismatch.stop_reason == "learn_front_mismatch", learned_mismatch.stop_reason)
for path, _ in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
end

writes = {}
learn_present = true
learn_body = learn_body:gsub("front_bid=com%.example%.other", "front_bid=com.ziyan.ziyan")
stop_present = false
sleep_calls = 0
runtime.front_bid = function() return "com.apple.Preferences" end
local mismatch = runtime.run_drill({
  profile_id = "agent_default_observe",
  bundle_id = "com.ziyan.ziyan",
})
assert(mismatch.state == "PAUSED_SAFE", mismatch.state)
assert(mismatch.stop_reason == "bundle_mismatch", mismatch.stop_reason)
for path, _ in pairs(writes) do
  assert(not path:find("/学习数据/", 1, true), path)
end

io.open = original_open
os.remove = original_remove
_G.mSleep = original_msleep
_G.ZIYAN_DRILL_LEARN_ID = nil
print("OFFLINE_TRUE_DRILL=PASS")
