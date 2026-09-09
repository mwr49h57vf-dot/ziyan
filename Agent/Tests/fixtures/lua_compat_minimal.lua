-- Minimal offline legacy-shaped fixture. No device coordinates or private data.
local ts = require("ts")
local sz = require("sz")
local TSLib = require("TSLib")

assert(type(ts) == "table", "require ts")
assert(type(sz) == "table", "require sz")
assert(type(TSLib) == "table", "require TSLib")
assert(type(sz.json) == "table", "sz.json")
assert(type(ts.config) == "table", "ts.config")
assert(type(init) == "function", "global init")

local ok, state = init("offline_fixture", 1)
assert(ok == true, "offline init must succeed")
assert(type(state) == "table", "offline init state")
assert(state.bid == "offline_fixture", "offline init bid")
assert(state.orient == 1, "offline init orientation")

local encoded = sz.json.encode({ mode = "offline", enabled = true })
local decoded = assert(sz.json.decode(encoded))
assert(decoded.mode == "offline", "sz.json encode/decode")
assert(decoded.enabled == true, "sz.json boolean")

assert(ts.config.set("contract_fixture", "mode", "offline") == "offline")
assert(ts.config.get("contract_fixture", "mode") == "offline")

local ftp_ok, ftp_reason = ts.ftp.upload(nil, nil, nil, nil, nil)
assert(ftp_ok == false, "ts.ftp must be rejected")
assert(ftp_reason == "unsupported:offline_ftp", "stable FTP rejection")

return true
