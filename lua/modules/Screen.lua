--[[ Zy.Screen — 屏幕同步模块
  真实屏 → 逻辑坐标；须经 Device 之后。
]]
local C = require("modules._ctx")
local M = { name = "Screen", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

function M.sync(orient, bid)
  C.require_pipeline("screen")
  orient = tonumber(orient) or C.orient or 1
  bid = bid or C.bid or _G.__ZIYAN_LAST_BID
  C.orient = orient
  C.set_bid(bid)
  local ok = false
  if defined("syncScreen") then
    ok = not not syncScreen(orient, bid)
  elseif defined("screenSync") then
    ok = not not screenSync(orient, bid)
  end
  C.mark_sync()
  return ok
end

function M.info()
  if defined("syncInfo") then return syncInfo() end
  local w, h = M.size()
  return { logic_w = w, logic_h = h }
end

function M.size()
  if defined("screenSize") then return screenSize() end
  if defined("getScreenSize") then return getScreenSize() end
  local p = _G.__ZIYAN_DEVICE_PROFILE or {}
  return tonumber(p.logic_w) or 1136, tonumber(p.logic_h) or 640
end

function M.snapshot(tag)
  C.require_pipeline("screen")
  tag = tostring(tag or "shot"):gsub("[^%w_%-]", "_")
  local path = "/private/var/mobile/Media/ZiYan/_zy_" .. tag .. ".png"
  if defined("snapshot") then pcall(snapshot, path); return path end
  if defined("screenDump") then pcall(screenDump, path); return path end
  if defined("dumpScreen") then pcall(dumpScreen, path); return path end
  return nil
end

function M.keep(on)
  if defined("keepScreen") then return keepScreen(not not on) end
  return false
end

return M
