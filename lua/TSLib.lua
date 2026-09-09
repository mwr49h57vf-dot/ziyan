-- Offline-only TSLib loading contract. No device, network, or process calls.
local ts = require("ts")
local sz = require("sz")
local actions = require("offline_actions")

local M = {
  name = "TSLib",
  version = "offline-1.0.0",
  ts = ts,
  sz = sz,
  actions = actions,
}

local function init(a, b)
  local bid, orient
  if b ~= nil then
    bid = tostring(a or "0")
    orient = tonumber(b) or 0
  else
    local numeric = tonumber(a)
    if numeric ~= nil then
      bid, orient = "0", numeric
    else
      bid, orient = tostring(a or "0"), 0
    end
  end
  if orient < 0 or orient > 2 then orient = 0 end
  local state = {
    bid = bid,
    orient = orient,
    mode = "offline",
  }
  _G.__ZIYAN_OFFLINE_INIT = state
  return true, state
end

M.init = init
ts.init = init
actions.install(ts)
M.Vision = actions.Vision
M.Touch = actions.Touch
M.App = actions.App
_G.ts = ts
_G.sz = sz
_G.init = init
return M
