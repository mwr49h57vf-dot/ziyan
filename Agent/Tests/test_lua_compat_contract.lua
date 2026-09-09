-- Offline Lua compatibility contract. Never loads Windows business scripts.
local root = (... and ... ~= "") and ... or "."
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/Agent/Tests/fixtures/?.lua",
  package.path,
}, ";")

_G.ZIYAN_COMPAT_CONFIG_DIR = nil
_G.ZIYAN_VAR = nil
local execute_called = false
local original_execute = os.execute
local popen_called = false
local original_popen = io.popen
os.execute = function()
  execute_called = true
  error("os.execute forbidden in offline Lua compatibility contract")
end
io.popen = function()
  popen_called = true
  error("io.popen forbidden in offline Lua compatibility contract")
end

local fixture = assert(loadfile(root .. "/Agent/Tests/fixtures/lua_compat_minimal.lua"))
assert(fixture() == true, "minimal fixture")

os.execute = original_execute
io.popen = original_popen
assert(execute_called == false, "compat modules must not execute processes")
assert(popen_called == false, "compat modules must not spawn process pipes")
print("LUA_COMPAT_CONTRACT_PASS modules=ts,sz,TSLib init=config=json ftp=unsupported")
