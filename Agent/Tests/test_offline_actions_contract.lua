-- Offline action compatibility contract. Never loads Windows business scripts.
local root = (... and ... ~= "") and ... or "."
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/Agent/Tests/fixtures/?.lua",
  package.path,
}, ";")

local execute_called = 0
local popen_called = 0
local original_execute = os.execute
local original_popen = io.popen
os.execute = function()
  execute_called = execute_called + 1
  error("os.execute forbidden in offline action contract")
end
io.popen = function()
  popen_called = popen_called + 1
  error("io.popen forbidden in offline action contract")
end

local fixture = assert(loadfile(root .. "/Agent/Tests/fixtures/lua_compat_actions.lua"))
assert(fixture() == true, "offline action fixture")

os.execute = original_execute
io.popen = original_popen
assert(execute_called == 0, "offline action stubs must not execute processes")
assert(popen_called == 0, "offline action stubs must not spawn process pipes")
print("OFFLINE_ACTIONS_CONTRACT_PASS")
