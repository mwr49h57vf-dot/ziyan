--[[ Zy.OptimizationAdvisor — 优化建议生成器（阶段 7.6.2）
  默认 proposal 模式：只产出建议，不自动改核心代码。
  须 human_confirm / confirm(id,true) 后才允许 Optimization.apply。
]]
local M = {
  name = "OptimizationAdvisor",
  version = "1.0.0",
  model = "ProposalOnlyAdvisor",
}

local function var_dir()
  local Zy = _G.Zy
  if Zy and Zy.File and Zy.File.varDir then return Zy.File.varDir() end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then return "/var/jb/usr/lib/ziyan/var" end
  return "/usr/lib/ziyan/var"
end

local function media()
  return "/private/var/mobile/Media/ZiYan"
end

local function ensure_dir(d)
  pcall(function() os.execute(string.format('mkdir -p "%s"', d)) end)
end

local function esc(s)
  return tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function append_jsonl(path, obj)
  local parts = {}
  for k, v in pairs(obj or {}) do
    if type(v) == "boolean" then
      parts[#parts + 1] = string.format('"%s":%s', k, v and "true" or "false")
    elseif type(v) == "number" then
      parts[#parts + 1] = string.format('"%s":%s', k, tostring(v))
    else
      parts[#parts + 1] = string.format('"%s":"%s"', k, esc(v))
    end
  end
  local line = "{" .. table.concat(parts, ",") .. "}\n"
  local f = io.open(path, "a")
  if f then f:write(line); f:close() end
  return line
end

-- 禁止自动修改的核心模块（proposal 不得指向直接改写这些源文件）
M.CORE_PROTECTED = {
  Touch = true, Coordinate = true, Screen = true, Device = true,
  Image = true, OCR = true, Verify = true, StateMachine = true,
}

local _pending = {}
local _seq = 0

local function next_id()
  _seq = _seq + 1
  return "prop_" .. tostring(os.time()) .. "_" .. tostring(_seq)
end

--- 生成优化建议（不执行）
-- @return proposal { id, status="pending", action, target_scope, touches_core, ... }
function M.advise(issue, analysis, classification, patch)
  issue = issue or {}
  analysis = analysis or {}
  classification = classification or {}
  patch = patch or {}
  local Zy = _G.Zy

  local action = patch.action or "tune"
  local target_scope = "generated_script" -- 默认只动生成脚本 / Knowledge
  local touches_core = false
  local solution = "调参生成脚本比例/词表"

  if action == "recover" then
    target_scope = "script_policy"
    solution = "调整 Script.recover_policy=" .. tostring(patch.recover_policy or "resync")
  elseif action == "repair" then
    target_scope = "generated_script"
    solution = "Script.repairScript 修复生成脚本"
  elseif action == "regenerate" then
    target_scope = "generated_script"
    solution = "Script.generateFromTask / AI.pipeline 重生脚本"
  elseif classification.category == "coordinate" then
    -- 坐标类：只建议比例偏移，禁止改 Coordinate 源码
    target_scope = "generated_script"
    touches_core = false
    solution = "禁止改 Coordinate 核心；仅 tune tapRatio 偏移"
  elseif classification.category == "device_compat" then
    target_scope = "knowledge_rule"
    solution = "写入 Knowledge 设备兼容规则；不改 objc/Device 核心"
  end

  -- 若误指向核心模块 → 降级为 proposal-only knowledge
  local mod = classification.module or issue.module
  if M.CORE_PROTECTED[tostring(mod)] and action ~= "tune" and action ~= "recover"
      and action ~= "repair" and action ~= "regenerate" then
    touches_core = true
    target_scope = "proposal_only"
    solution = "核心模块 " .. tostring(mod) .. " 禁止自动修改；仅记录建议"
    action = "record_only"
  end

  local id = next_id()
  local proposal = {
    id = id,
    status = "pending",
    confirmed = false,
    ts = os.time(),
    time = os.date("%Y-%m-%d %H:%M:%S"),
    issue_type = issue.type or "",
    category = classification.category or "",
    category_zh = classification.category_zh or "",
    module = tostring(mod or ""),
    reason = tostring(analysis.root_cause or issue.reason or ""),
    action = action,
    solution = solution,
    target_scope = target_scope,
    touches_core = touches_core,
    allow_auto_core = false, -- 硬禁止
    patch_action = patch.action or action,
    recover_policy = patch.recover_policy or "",
    bid = issue.bid or "",
    goal = issue.goal or "",
    phase = issue.phase or "",
  }
  _pending[id] = proposal
  M._last = proposal

  ensure_dir(media() .. "/opt")
  append_jsonl(var_dir() .. "/.ziyan_opt_proposals.jsonl", {
    ts = proposal.ts, id = id, status = "pending", action = action,
    category = proposal.category, module = proposal.module,
    solution = solution, touches_core = touches_core, event = "advise",
  })
  if Zy and Zy.Log and Zy.Log.write then
    Zy.Log.write("OptimizationAdvisor.advise " .. id .. " " .. action)
  end
  return proposal
end

--- 人工确认 / 拒绝
function M.confirm(proposal_id, accepted)
  local p = _pending[tostring(proposal_id)] or M._last
  if type(proposal_id) == "table" then p = proposal_id; proposal_id = p.id end
  if not p then return false, "proposal_not_found" end
  if accepted == false then
    p.status = "rejected"
    p.confirmed = false
    append_jsonl(var_dir() .. "/.ziyan_opt_proposals.jsonl", {
      ts = os.time(), id = p.id, status = "rejected", event = "confirm",
    })
    return false, "rejected"
  end
  if p.touches_core and p.allow_auto_core ~= true then
    -- 即使确认，也不允许 apply 改核心；仅标记为 confirmed_record
    p.status = "confirmed_record_only"
    p.confirmed = true
    p.apply_allowed = false
    append_jsonl(var_dir() .. "/.ziyan_opt_proposals.jsonl", {
      ts = os.time(), id = p.id, status = p.status, event = "confirm_core_blocked",
    })
    return true, "confirmed_but_core_blocked"
  end
  p.status = "confirmed"
  p.confirmed = true
  p.apply_allowed = true
  append_jsonl(var_dir() .. "/.ziyan_opt_proposals.jsonl", {
    ts = os.time(), id = p.id, status = "confirmed", event = "confirm",
  })
  return true, p
end

function M.reject(proposal_id)
  return M.confirm(proposal_id, false)
end

function M.get(proposal_id)
  if proposal_id then return _pending[tostring(proposal_id)] end
  return M._last
end

function M.pending()
  local list = {}
  for _, p in pairs(_pending) do
    if p.status == "pending" then list[#list + 1] = p end
  end
  return list
end

function M.canApply(proposal)
  proposal = proposal or M._last
  if not proposal then return false, "no_proposal" end
  if proposal.touches_core and proposal.allow_auto_core ~= true then
    return false, "core_protected"
  end
  if proposal.status == "confirmed" and proposal.apply_allowed then
    return true
  end
  return false, "need_human_confirm"
end

return M
