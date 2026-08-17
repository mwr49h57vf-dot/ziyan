-- Offline smoke of the state machine. No device required.
package.path = package.path .. ";./Agent/Core/?.lua;./?.lua"
_G.ZIYAN_VAR = "/tmp/ziyan_agent_test_var"
os.execute("mkdir -p /tmp/ziyan_agent_test_var")
local f = io.open("/tmp/ziyan_agent_test_var/.ziyan_front_bid", "w")
f:write("com.ziyan.ziyan\n")
f:close()
f = io.open("/tmp/ziyan_agent_test_var/.ziyan_frame_seq", "w")
f:write("3\n")
f:close()
local runtime = dofile("Agent/Core/agent_runtime.lua")
local s = runtime.run_smoke({ profile_id = "agent_smoke", bundle_id = "com.ziyan.ziyan" })
assert(s.state == "STOPPED", s.state)
assert(s.action_count == 1, tostring(s.action_count))
print("OFFLINE_SMOKE_PASS state=" .. s.state)
