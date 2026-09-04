--[[ Zy.RuleEngine — 通用规则表与状态转移模块
  不绑定具体游戏；规则由调用方提供，结果带 trace 便于复现和回滚。
]]
local M = { name = "RuleEngine", version = "1.0.0" }

function M.new(opts)
  opts = opts or {}
  return {
    id = tostring(opts.id or "rules"),
    state = opts.initial_state or "initial",
    score = tonumber(opts.score) or 0,
    turn = 0,
    rules = {},
    trace = {},
    paused = false,
  }
end

function M.add(engine, rule)
  assert(type(engine) == "table", "engine required")
  assert(type(rule) == "table" and type(rule.id) == "string", "rule.id required")
  assert(type(rule.when) == "function" and type(rule["then"]) == "function", "rule callbacks required")
  engine.rules[#engine.rules + 1] = rule
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

function M.step(engine, context)
  assert(type(engine) == "table", "engine required")
  if engine.paused then return false, "paused", engine end
  context = context or {}
  engine.turn = engine.turn + 1
  for _, rule in ipairs(engine.rules) do
    local ok, matched = pcall(rule.when, context, engine)
    if ok and matched then
      local applied, result = pcall(rule["then"], context, engine)
      local event = {
        turn = engine.turn, rule = rule.id, matched = true,
        applied = applied, result = result, state = engine.state, score = engine.score,
      }
      engine.trace[#engine.trace + 1] = event
      if not applied then return false, "rule_error:" .. rule.id, event end
      return true, event, engine
    end
  end
  local event = { turn = engine.turn, rule = nil, matched = false, state = engine.state, score = engine.score }
  engine.trace[#engine.trace + 1] = event
  return false, "no_rule", event
end

function M.snapshot(engine)
  return {
    id = engine.id, state = engine.state, score = engine.score,
    turn = engine.turn, paused = engine.paused, pause_reason = engine.pause_reason,
    trace = engine.trace,
  }
end

function M.replay(engine, contexts)
  local old = engine.trace
  engine.trace = {}
  local out = {}
  for _, context in ipairs(contexts or {}) do
    local ok, event = M.step(engine, context)
    out[#out + 1] = { ok = ok, event = event }
  end
  return out, old
end

return M
