--[[ Game State Machine — 通用交互状态（引擎层）
  boot→loading→login→menu→role→running→error
  兼容旧相位名：main→running, privacy→login, task→running
]]
local M = { module = "state_machine", version = "1.2.0", model = "InteractionStateMachine" }

local function defined(n) return type(_G[n]) == "function" end

M.STATES = {
  "boot", "loading", "login", "menu", "role", "running", "error", "unknown",
  -- 兼容别名保留在归一函数
}

M.EDGES = {
  boot = { "loading", "login", "menu", "running", "unknown" },
  loading = { "login", "menu", "role", "running", "error", "boot" },
  login = { "loading", "menu", "role", "running", "error" },
  menu = { "role", "running", "login", "error" },
  role = { "running", "menu", "error" },
  running = { "running", "menu", "error", "login" },
  error = { "boot", "login", "menu", "running" },
  unknown = { "boot", "loading", "login", "menu", "running" },
}

M._last = { bid = "", state = "", label = "", ok = false }

local function normalize(ph)
  ph = tostring(ph or "unknown")
  if ph == "main" or ph == "task" or ph == "playing" then return "running" end
  if ph == "privacy" or ph == "server" then return "login" end
  if ph == "role_select" or ph == "entering" then return "role" end
  return ph
end

function M.current(bid)
  bid = bid or _G.__ZIYAN_LAST_BID
  if type(_G.Zy) == "table" and _G.Zy.Game and type(_G.Zy.Game.phase) == "function" then
    return normalize(_G.Zy.Game.phase(bid))
  end
  if defined("frontAppBid") and bid then
    local fr = tostring(frontAppBid() or "")
    if fr ~= "" and fr ~= tostring(bid) then
      return "boot"
    end
  end
  if defined("gamePhase") then
    return normalize(gamePhase(bid))
  end
  if defined("gameDetectState") then
    local st = tostring(gameDetectState(bid) or "unknown")
    if st == "playing" then return "running" end
    if st == "login" or st == "privacy" then return "login" end
    return normalize(st)
  end
  return "unknown"
end

function M.suggest(state)
  state = normalize(state)
  local map = {
    boot = "launch_app_and_sync",
    loading = "wait_and_reclassify",
    login = "pause_auth_skip_credentials",
    menu = "select_primary_entry_then_verify",
    role = "confirm_identity_then_verify",
    running = "observe_or_task_step",
    error = "capture_and_recover",
    unknown = "sync_vision_reclassify",
  }
  return map[state] or "sync_vision_reclassify"
end

function M.can_transit(from_st, to_st)
  local edges = M.EDGES[tostring(from_st)] or M.EDGES.unknown
  for _, e in ipairs(edges) do
    if e == tostring(to_st) then return true end
  end
  return false
end

--- 若上一步同 bid+state+label 且未成功，禁止再执行（防重复点击）
function M.blocked_repeat(bid, state, label)
  local L = M._last
  if L.bid == tostring(bid) and L.state == tostring(state)
      and L.label == tostring(label) and L.ok == false then
    return true
  end
  return false
end

function M.remember_step(bid, state, label, ok)
  M._last = {
    bid = tostring(bid or ""),
    state = tostring(state or ""),
    label = tostring(label or ""),
    ok = not not ok,
  }
end

--- 一步：状态 → 单次动作 → 强制验证；禁止同失败动作连点
function M.step(bid, handlers, wait_ms)
  handlers = handlers or {}
  bid = bid or _G.__ZIYAN_LAST_BID
  if defined("syncScreen") then pcall(syncScreen, 1, bid) end
  local st = M.current(bid)
  local label = M.suggest(st)
  if M.blocked_repeat(bid, st, label) then
    if defined("verifyFailReport") then
      verifyFailReport({
        bid = bid, phase = st,
        reason = "repeat_blocked:" .. label,
        module = "state_machine",
        fix = "stop; reclassify or change auth path; do not re-tap",
        tag = "repeat_block",
      })
    end
    return false, st, st, "repeat_blocked:" .. label
  end
  local fn = handlers[st] or handlers.default
  if type(fn) ~= "function" then
    return false, st, st, "no_handler:" .. st
  end
  if defined("verifyAct") then
    local ok, after, reason = verifyAct(bid, label, function() fn(bid, st) end, wait_ms)
    local after_st = after and after.phase or M.current(bid)
    M.remember_step(bid, st, label, ok)
    return ok, st, after_st, label .. ":" .. tostring(reason)
  end
  pcall(fn, bid, st)
  local sleep_ms = wait_ms or 1200
  if defined("mSleep") then mSleep(sleep_ms) end
  local after_st = M.current(bid)
  local ok = after_st ~= st and not (st == "login" and after_st == "login")
  M.remember_step(bid, st, label, ok)
  return ok, st, after_st, label
end

function M.install(engine)
  _G.gameStateCurrent = function(bid) return M.current(bid) end
  _G.gameStateSuggest = function(st) return M.suggest(st) end
  _G.gameStateStep = function(bid, handlers, wait_ms) return M.step(bid, handlers, wait_ms) end
  _G.ZiYanStateMachine = M
  if engine then engine.state_machine = M end
  return M
end

return M
