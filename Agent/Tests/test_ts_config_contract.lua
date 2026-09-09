-- Offline ts.config handle and path-boundary contract.
package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

local ts = require("ts")
local config = assert(ts.config)

for _, name in ipairs({ "open", "get", "save", "delete", "close" }) do
  assert(type(config[name]) == "function", "missing ts.config." .. name)
end
assert(config.root() == config.allowlisted_root)

_G.ZIYAN_COMPAT_CONFIG_DIR = nil
_G.ZIYAN_VAR = nil

local handle, err = config.open("contract_fixture")
assert(type(handle) == "table", tostring(err))
assert(handle.namespace == "contract_fixture", "handle namespace")
assert(handle.state == "open", "handle state")
assert(config.get(handle, "missing", "default") == "default")
assert(config.save(handle, "mode", "offline") == true)
assert(config.save(handle, { enabled = true }) == true)
assert(config.get(handle, "mode") == "offline")
assert(config.get(handle, "enabled") == true)
assert(config.delete(handle, "mode") == true)
assert(config.get(handle, "mode", "deleted") == "deleted")
assert(config.close(handle) == true)
assert(handle.state == "closed", "closed handle state")
local closed_value, closed_reason = config.get(handle, "enabled")
assert(closed_value == nil and closed_reason == "closed_handle")
assert(config.close(handle) == false)

local function rejected(value, expected)
  local got, reason = config.open(value)
  assert(got == false and reason == expected,
    string.format("expected %s for %q, got %s / %s",
      expected, tostring(value), tostring(got), tostring(reason)))
end

_G.ZIYAN_COMPAT_CONFIG_DIR = "/tmp/arbitrary-config-root"
rejected("env_root", "invalid_config_root")
_G.ZIYAN_COMPAT_CONFIG_DIR = nil
_G.ZIYAN_VAR = "/tmp/arbitrary-ziyan-var"
rejected("var_root", "invalid_config_root")
_G.ZIYAN_VAR = nil

rejected("../escape", "invalid_config_name")
rejected("nested/name", "invalid_config_name")
rejected("line\nbreak", "invalid_config_name")
rejected("nul\000byte", "invalid_config_name")
rejected("/tmp/outside.json", "invalid_config_path")

local legacy_prefix = "/private/var/mobile/Media/TouchSprite/config/"
local legacy = assert(config.open(legacy_prefix .. "legacy_fixture.json"))
assert(legacy.namespace == "legacy_legacy_fixture")
assert(config.path(legacy_prefix .. "legacy_fixture.json")
  == config.root() .. "/legacy_legacy_fixture.json")
assert(config.save(legacy, "value", 42) == true)
assert(config.get(legacy, "value") == 42)
assert(config.close(legacy) == true)

-- The backend is memory-only; a path with a symlink-like component is never resolved.
rejected(legacy_prefix .. "link/escape.json", "invalid_config_path")
rejected(legacy_prefix .. "../escape.json", "invalid_config_path")

print("TS_CONFIG_CONTRACT_PASS handles=5 boundaries=env,relative,nul,newline,symlink,legacy")
