--[[ Zy.Decision — 可追踪、可重放的通用自动决策模块
  决策只选择调用方注册的动作；不包含账号、支付或专用游戏内容。
]]
local M = { name = "Decision", version = "1.0.0" }

function M.new(opts)
  opts = opts or {}
  return {
    id = tostring(opts.id or "decision"),
    actions = {}, trace = {}, paused = false, retries = {}, cursor = 0,
  }
end

function M.add(engine, action)
  assert(type(engine) == "table", "engine required")
  assert(type(action) == "table" and type(action.id) == "string", "action.id required")
  assert(type(action.when) == "function" and type(action.run) == "function", "action callbacks required")
  engine.actions[#engine.actions + 1] = action
  return true
end

function M.pause(engine, reason)
  engine.paused = true
  engine.pause_reason = tostring(reason or "paused")
  return true
end

function M.resume(engine)
  engine.paused = false
  engine.pause_reason = nil
  return true
end

function M.choose(engine, context)
  if engine.paused then return false, "paused" end
  context = context or {}
  engine.cursor = engine.cursor + 1
  for _, action in ipairs(engine.actions) do
    local ok, selected = pcall(action.when, context, engine)
    if ok and selected then
      local ran, result = pcall(action.run, context, engine)
      local event = { cursor = engine.cursor, action = action.id, ran = ran, result = result }
      engine.trace[#engine.trace + 1] = event
      if not ran then return false, "action_error:" .. action.id, event end
      return true, event
    end
  end
  local event = { cursor = engine.cursor, action = nil, ran = false, result = "no_action" }
  engine.trace[#engine.trace + 1] = event
  return false, "no_action", event
end

function M.retry(engine, action_id, limit)
  limit = tonumber(limit) or 3
  local n = (engine.retries[action_id] or 0) + 1
  engine.retries[action_id] = n
  if n > limit then return false, "retry_limit" end
  return true, n
end

function M.replay(engine, contexts)
  local out = {}
  for _, context in ipairs(contexts or {}) do
    local ok, reason, event = M.choose(engine, context)
    out[#out + 1] = { ok = ok, reason = reason, event = event }
  end
  return out
end

function M.snapshot(engine)
  return {
    id = engine.id, paused = engine.paused, pause_reason = engine.pause_reason,
    cursor = engine.cursor, retries = engine.retries, trace = engine.trace,
  }
end

return M
