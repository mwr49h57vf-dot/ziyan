--[[ Zy.StateMachine — 通用状态机模块层
  管道末端：… → Verify → StateMachine
]]
local C = require("modules._ctx")
local M = { name = "StateMachine", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

function M.current(bid)
  bid = bid or C.bid
  local Zy = _G.Zy
  if Zy and Zy.Game and Zy.Game.phase then
    return Zy.Game.phase(bid)
  end
  if defined("gameStateCurrent") then return gameStateCurrent(bid) end
  return "unknown"
end

function M.suggest(st)
  local Zy = _G.Zy
  if Zy and Zy.Game and Zy.Game.suggest then return Zy.Game.suggest(st) end
  if defined("gameStateSuggest") then return gameStateSuggest(st) end
  return "sync_vision_reclassify"
end

function M.step(bid, handlers, wait_ms)
  bid = bid or C.bid
  if defined("gameStateStep") then
    return gameStateStep(bid, handlers, wait_ms)
  end
  local st = M.current(bid)
  local label = M.suggest(st)
  local fn = handlers and (handlers[st] or handlers.default)
  if type(fn) ~= "function" then
    return false, st, st, "no_handler:" .. st
  end
  local Zy = _G.Zy
  if Zy and Zy.Verify then
    local ok, after, reason = Zy.Verify.act(label, function() fn(bid, st) end, wait_ms)
    local after_st = after and after.phase or M.current(bid)
    return ok, st, after_st, tostring(reason)
  end
  pcall(fn, bid, st)
  return false, st, M.current(bid), "no_verify"
end

function M.canTransit(from_st, to_st)
  if defined("ZiYanStateMachine") and ZiYanStateMachine.can_transit then
    return ZiYanStateMachine.can_transit(from_st, to_st)
  end
  return true
end

return M
