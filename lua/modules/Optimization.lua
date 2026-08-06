--[[ Zy.Optimization — 长期自主优化编排（阶段 7.6 → 7.6.2）
  2.0 闭环：collect→detect→classify→analyze→propose→human_confirm→apply→verify→record
  默认 proposal 模式：禁止自动修改核心代码；须 human_confirm 才 apply。
  委托：IssueClassifier / OptimizationAdvisor / OptimizationRollback / AI / Script / Knowledge
]]
local M = {
  name = "Optimization",
  version = "2.0.0",
  model = "LongTermOptLoop",
}

local function media()
  return "/private/var/mobile/Media/ZiYan"
end

local function var_dir()
  local Zy = _G.Zy
  if Zy and Zy.File and Zy.File.varDir then
    return Zy.File.varDir()
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function ensure_dir(d)
  pcall(function() os.execute(string.format('mkdir -p "%s"', d)) end)
end

local function versions_dir()
  local d = media() .. "/opt/versions"
  ensure_dir(d)
  return d
end

local function history_path()
  local d = media() .. "/opt"
  ensure_dir(d)
  return d .. "/optimization_history.jsonl"
end

local function history_var_path()
  return var_dir() .. "/.ziyan_opt_history.jsonl"
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

local function log(msg)
  local Zy = _G.Zy
  if Zy and Zy.Log and Zy.Log.write then Zy.Log.write(msg)
  else print(tostring(msg)) end
end

local function auto_enabled(opts)
  opts = opts or {}
  if opts.auto_opt == true then return true end
  local Zy = _G.Zy
  if Zy and Zy.Script and Zy.Script.get and Zy.Script.get("auto_opt") then
    return true
  end
  return false
end

--------------------------------------------------------------------------
-- collect
--------------------------------------------------------------------------
function M.collect(run_ctx)
  run_ctx = run_ctx or {}
  local Zy = assert(_G.Zy, "Zy required")
  local prof = {}
  if Zy.Device and Zy.Device.profile then
    pcall(function()
      if Zy.Device.refresh then Zy.Device.refresh() end
      prof = Zy.Device.profile() or {}
    end)
  end
  local w, h = 0, 0
  if Zy.Screen and Zy.Screen.size then
    w, h = Zy.Screen.size()
  end
  local phase = run_ctx.phase
  if not phase and Zy.Game and Zy.Game.phase then
    local ok, p = pcall(Zy.Game.phase, run_ctx.bid)
    if ok then phase = p end
  end
  local suggest = run_ctx.suggest
  if not suggest and Zy.StateMachine and Zy.StateMachine.suggest then
    local ok, s = pcall(Zy.StateMachine.suggest, phase)
    if ok then suggest = s end
  end
  local metrics = {
    ts = os.time(),
    time = os.date("%Y-%m-%d %H:%M:%S"),
    bid = tostring(run_ctx.bid or (Zy.Script and Zy.Script.get and Zy.Script.get("bid")) or ""),
    goal = tostring(run_ctx.goal or (Zy.Script and Zy.Script.get and Zy.Script.get("goal")) or ""),
    path = tostring(run_ctx.path or (Zy.Script and Zy.Script.get and Zy.Script.get("last_generated")) or ""),
    iter = tonumber(run_ctx.iter) or 0,
    device = tostring(prof.model or ""),
    os = tostring(prof.os or prof.system or ""),
    dpi = tostring(prof.dpi or ""),
    logic_w = w,
    logic_h = h,
    design_w = run_ctx.design_w or (Zy.Script and Zy.Script.get and Zy.Script.get("design_w")),
    design_h = run_ctx.design_h or (Zy.Script and Zy.Script.get and Zy.Script.get("design_h")),
    orient = run_ctx.orient or (Zy.Script and Zy.Script.get and Zy.Script.get("orient")),
    phase = tostring(phase or ""),
    suggest = tostring(suggest or ""),
    last_act = tostring(run_ctx.last_act or (Zy.Script and Zy.Script.get and Zy.Script.get("last_act")) or ""),
    last_ok = run_ctx.last_ok,
    last_reason = tostring(run_ctx.last_reason or (Zy.Script and Zy.Script.get and Zy.Script.get("last_reason")) or ""),
    last_error = tostring(run_ctx.last_error or (Zy.Script and Zy.Script.lastError and Zy.Script.lastError()) or ""),
    loop_i = tonumber(run_ctx.loop_i or (Zy.Script and Zy.Script.get and Zy.Script.get("loop_i")) or 0),
    recover_n = tonumber(run_ctx.recover_n or (Zy.Script and Zy.Script.get and Zy.Script.get("recover_n")) or 0),
    phase_unchanged_n = tonumber(run_ctx.phase_unchanged_n or 0),
    ocr = tostring(run_ctx.ocr or ""),
    vision_kind = tostring(run_ctx.vision_kind or ""),
    vision_hit = not not run_ctx.vision_hit,
    shot = tostring(run_ctx.shot or ""),
    fingerprint_before = tostring(run_ctx.fingerprint_before or ""),
    fingerprint_after = tostring(run_ctx.fingerprint_after or ""),
    code_ver = tostring(run_ctx.code_ver or (Zy.AI and Zy.AI.version) or ""),
    elapsed_ms = tonumber(run_ctx.elapsed_ms) or 0,
    event = "opt_collect",
    force_issue = run_ctx.force_issue,
    force_reason = run_ctx.force_reason,
  }
  if metrics.last_ok == nil and Zy.Script and Zy.Script.get then
    metrics.last_ok = Zy.Script.get("last_ok")
  end
  if type(metrics.last_ok) ~= "boolean" then
    metrics.last_ok = nil -- 未知，避免误报 vision_miss
  end

  append_jsonl(var_dir() .. "/.ziyan_opt_run.jsonl", {
    ts = metrics.ts, bid = metrics.bid, goal = metrics.goal, phase = metrics.phase,
    last_ok = metrics.last_ok, last_reason = metrics.last_reason, path = metrics.path,
    event = "collect",
  })
  M._last_metrics = metrics
  return metrics
end

--------------------------------------------------------------------------
-- detect
--------------------------------------------------------------------------
function M.detect(metrics)
  metrics = metrics or M._last_metrics or {}
  local issues = {}
  local function add(t, reason, severity)
    issues[#issues + 1] = {
      type = t,
      reason = reason or t,
      severity = severity or "med",
      phase = metrics.phase,
      bid = metrics.bid,
      goal = metrics.goal,
      path = metrics.path,
      ts = os.time(),
    }
  end

  local nstuck = tonumber(metrics.phase_unchanged_n) or 0
  if nstuck >= 3 or (metrics.last_reason == "no_change" and nstuck >= 1) then
    add("phase_stuck", "phase_unchanged=" .. tostring(nstuck), "high")
  end
  if metrics.last_ok == false and (tostring(metrics.last_reason):find("no_change") or metrics.last_reason == "verify_fail") then
    add("verify_fail", tostring(metrics.last_reason), "high")
  end
  if metrics.last_ok == false and metrics.ocr == "" and metrics.vision_hit == false then
    add("vision_miss", "no_ocr_no_vision", "med")
  end
  if metrics.ocr == "empty" or metrics.ocr == "(empty)" then
    add("ocr_empty", "ocr_empty", "med")
  end
  if metrics.fingerprint_before ~= "" and metrics.fingerprint_before == metrics.fingerprint_after
      and metrics.last_act ~= "" then
    add("tap_no_effect", "fingerprint_unchanged", "high")
  end
  local err = tostring(metrics.last_error or "")
  if err ~= "" and err ~= "nil" then
    if err:find("timeout") or err:find("超时") then
      add("timeout", err, "high")
    else
      add("crash", err:sub(1, 160), "high")
    end
  end
  local path = metrics.path
  if type(path) == "string" and path ~= "" then
    local f = io.open(path, "r")
    if f then
      local body = f:read("*a") or ""; f:close()
      if body:find("Touch%.tap%s*%(") or body:find("Touch%.click") then
        add("forbidden_coord", "physical_tap_in_script", "crit")
      end
    end
  end
  if metrics.force_issue then
    -- 强制 issue 置顶，便于冒烟/人工指定
    table.insert(issues, 1, {
      type = tostring(metrics.force_issue),
      reason = metrics.force_reason or "forced",
      severity = "med",
      phase = metrics.phase,
      bid = metrics.bid,
      goal = metrics.goal,
      path = metrics.path,
      ts = os.time(),
    })
  end

  for _, iss in ipairs(issues) do
    append_jsonl(var_dir() .. "/.ziyan_opt_issues.jsonl", {
      ts = iss.ts, type = iss.type, reason = iss.reason, severity = iss.severity,
      bid = iss.bid, goal = iss.goal, phase = iss.phase, path = iss.path, event = "detect",
    })
  end
  M._last_issues = issues
  return issues
end

--------------------------------------------------------------------------
-- analyze
--------------------------------------------------------------------------
function M.analyze(issue)
  issue = issue or {}
  local Zy = _G.Zy
  local t = tostring(issue.type or "unknown")
  local analysis = {
    issue_type = t,
    root_cause = t,
    module = "Script",
    fix_hint = "resync",
    kb_hits = {},
  }
  if t == "phase_stuck" or t == "verify_fail" or t == "tap_no_effect" then
    analysis.module = "Touch/Verify"
    analysis.fix_hint = "tune_ratio_or_ocr"
    analysis.root_cause = "action_no_ui_change"
  elseif t == "ocr_empty" or t == "vision_miss" then
    analysis.module = "OCR/Vision"
    analysis.fix_hint = "expand_words_or_color"
    analysis.root_cause = "perception_miss"
  elseif t == "timeout" then
    analysis.module = "Script"
    analysis.fix_hint = "relaunch"
    analysis.root_cause = "wait_timeout"
  elseif t == "crash" then
    analysis.module = "Script"
    analysis.fix_hint = "repair_script"
    analysis.root_cause = "runtime_error"
  elseif t == "forbidden_coord" then
    analysis.module = "Script.validate"
    analysis.fix_hint = "regenerate_ratio_only"
    analysis.root_cause = "policy_violation"
  end
  if Zy and Zy.Knowledge and Zy.Knowledge.query then
    analysis.kb_hits = Zy.Knowledge.query(t, 3)
  end
  if Zy and Zy.Game and Zy.Game.suggest and issue.phase then
    local ok, s = pcall(Zy.Game.suggest, issue.phase)
    if ok then analysis.game_suggest = s end
  end
  return analysis
end

--------------------------------------------------------------------------
-- propose
--------------------------------------------------------------------------
function M.propose(issue, analysis)
  issue = issue or {}
  analysis = analysis or M.analyze(issue)
  local hint = analysis.fix_hint or "tune_ratio_or_ocr"
  local patch = {
    issue_type = issue.type,
    action = "tune",
    tune = { shift_x = 0.02, shift_y = -0.04 },
    recover_policy = "resync",
    expand_words = { "登录", "领取", "确定", "奖励" },
    wait_ms = 1200,
  }
  if hint == "relaunch" then
    patch.action = "recover"
    patch.recover_policy = "relaunch"
  elseif hint == "repair_script" then
    patch.action = "repair"
  elseif hint == "regenerate_ratio_only" or hint == "expand_words_or_color" then
    patch.action = "regenerate"
  elseif hint == "tune_ratio_or_ocr" then
    patch.action = "tune"
  end
  if analysis.issue_type == "ocr_empty" then
    patch.action = "regenerate"
  end
  M._last_patch = patch
  return patch
end

--------------------------------------------------------------------------
-- apply
--------------------------------------------------------------------------
function M.apply(plan, patch, opts)
  opts = opts or {}
  patch = patch or M._last_patch or {}
  plan = plan or {}
  local Zy = assert(_G.Zy, "Zy required")
  local bid = opts.bid or plan.bid or "com.example.app"
  local goal = opts.goal or plan.goal or "opt_cycle"
  local dw = tonumber(opts.design_w or plan.design_w) or 1136
  local dh = tonumber(opts.design_h or plan.design_h) or 640
  local result = { ok = false, path = nil, action = patch.action }

  if patch.recover_policy and Zy.Script and Zy.Script.set then
    Zy.Script.set("recover_policy", patch.recover_policy)
  end

  if patch.action == "tune" and Zy.AI and Zy.AI.optimize then
    local new_plan = select(1, Zy.AI.optimize(plan, {
      reason = opts.reason or patch.issue_type or "opt_tune",
      ctx = { bid = bid, phase = plan.phase or "unknown" },
      iter = opts.iter or 1,
    }))
    new_plan = new_plan or plan
    if patch.tune and new_plan.action then
      new_plan.action.rx = math.max(0.05, math.min(0.95, (new_plan.action.rx or 0.5) + (patch.tune.shift_x or 0)))
      new_plan.action.ry = math.max(0.05, math.min(0.95, (new_plan.action.ry or 0.7) + (patch.tune.shift_y or 0)))
    end
    if patch.expand_words then new_plan.words = patch.expand_words end
    local src = Zy.AI.generate(new_plan, { max_loop = opts.max_loop or 3 })
    local path = Zy.AI.save(src, { goal = goal, bid = bid, plan = new_plan, name = "opt_tune_" .. tostring(os.time()) .. ".lua" })
    result.ok, result.path, result.plan, result.src = true, path, new_plan, src
  elseif patch.action == "repair" and Zy.Script and Zy.Script.repairScript then
    local src_path = opts.path or plan.path or ""
    local ok, path, body = Zy.Script.repairScript(src_path, opts.reason or "opt_repair", {
      bid = bid, goal = goal, design_w = dw, design_h = dh,
    })
    result.ok, result.path, result.src = ok, path, body
  elseif patch.action == "regenerate" and Zy.Script and Zy.Script.generateFromTask then
    local ok, path, src, new_plan = Zy.Script.generateFromTask(goal, {
      bid = bid, design_w = dw, design_h = dh, collect = false, max_loop = opts.max_loop or 3,
    })
    result.ok, result.path, result.src, result.plan = ok, path, src, new_plan
  elseif patch.action == "recover" then
    result.ok = true
    result.path = opts.path or plan.path
    result.note = "recover_policy=" .. tostring(patch.recover_policy)
  else
    -- fallback regenerate
    if Zy.AI and Zy.AI.pipeline then
      local rep = Zy.AI.pipeline(goal, {
        bid = bid, design_w = dw, design_h = dh, offline = true, light_test = true, max_loop = 2,
        name = "opt_fallback_" .. tostring(os.time()) .. ".lua",
      })
      result.ok = not not rep.ok
      result.path = rep.path
      result.plan = rep.plan
    end
  end
  M._last_apply = result
  return result
end

--------------------------------------------------------------------------
-- verify
--------------------------------------------------------------------------
function M.verify(path, opts)
  opts = opts or {}
  local Zy = assert(_G.Zy, "Zy required")
  local report = { ok = true, static_ok = true, test_ok = true, path = path }
  local body = ""
  if type(path) == "string" and path ~= "" then
    local f = io.open(path, "r")
    if f then body = f:read("*a") or ""; f:close() end
  end
  if Zy.Script and Zy.Script.validate then
    local vok, vrep = Zy.Script.validate({ code = body, require_begin = false })
    report.static_ok = vok
    report.validate = vrep
    if not vok then report.ok = false end
  end
  if body:find("Touch%.tap%s*%(") or body:find("Touch%.click") then
    report.ok = false
    report.static_ok = false
    report.forbidden = true
  end
  if opts.skip_test then
    report.test_ok = true
    report.test_detail = { phase = "skipped" }
  elseif path and path ~= "" and Zy.AI and Zy.AI.test then
    local tok, detail = Zy.AI.test(path, {
      goal = opts.goal, bid = opts.bid, light_test = opts.light_test ~= false, load_only = opts.load_only,
    })
    report.test_ok = tok
    report.test_detail = detail
    if not tok then report.ok = false end
  end
  M._last_verify = report
  return report.ok, report
end

--------------------------------------------------------------------------
-- commit
--------------------------------------------------------------------------
function M.commit(version_meta)
  version_meta = version_meta or {}
  local Zy = _G.Zy
  local ver = version_meta.version or ("v" .. tostring(os.time()))
  local dir = versions_dir() .. "/" .. ver
  ensure_dir(dir)
  local path = version_meta.path
  local src = version_meta.src
  if (not src or src == "") and path then
    local f = io.open(path, "r")
    if f then src = f:read("*a"); f:close() end
  end
  if src and src ~= "" then
    local out = dir .. "/script.lua"
    local f = io.open(out, "w")
    if f then f:write(src); f:close() end
    version_meta.version_path = out
  end
  local meta_path = dir .. "/meta.json"
  local mf = io.open(meta_path, "w")
  if mf then
    mf:write(string.format(
      '{"version":"%s","goal":"%s","bid":"%s","issue":"%s","patch":"%s","ok":%s,"path":"%s"}\n',
      esc(ver), esc(version_meta.goal), esc(version_meta.bid),
      esc(version_meta.issue_type), esc(version_meta.patch_action),
      version_meta.ok and "true" or "false", esc(version_meta.path or "")
    ))
    mf:close()
  end
  append_jsonl(var_dir() .. "/.ziyan_opt_versions.jsonl", {
    ts = os.time(), version = ver, goal = version_meta.goal or "",
    bid = version_meta.bid or "", ok = not not version_meta.ok,
    path = version_meta.path or "", event = "commit",
  })
  if Zy and Zy.Knowledge and Zy.Knowledge.save then
    Zy.Knowledge.save({
      task = version_meta.goal, bid = version_meta.bid, path = version_meta.path,
      ok = version_meta.ok, phase = version_meta.phase,
      issue_type = version_meta.issue_type, patch = version_meta.patch_action,
      version = ver, metrics = version_meta.metrics_summary,
      optimize = "Optimization.commit", event = "opt_commit",
      flow = "collect>detect>analyze>propose>apply>verify>commit",
      rules = version_meta.rules or "",
    })
  end
  M._last_version = ver
  log("Optimization.commit " .. tostring(ver))
  return ver, dir
end

--------------------------------------------------------------------------
-- history — optimization_history.jsonl
--------------------------------------------------------------------------
function M.historyPath()
  -- 优先可读：若 Media 历史存在用 Media，否则 var 备份
  local media_p = history_path()
  local var_p = history_var_path()
  if io.open(media_p, "r") then return media_p end
  if io.open(var_p, "r") then return var_p end
  return media_p
end

--- 写入优化历史（Media + var 双写）
-- entry: time/module/issue/reason/solution/device/result/version/...
function M.recordHistory(entry)
  entry = entry or {}
  local row = {
    time = entry.time or os.date("%Y-%m-%d %H:%M:%S"),
    ts = entry.ts or os.time(),
    module = tostring(entry.module or ""),
    issue = tostring(entry.issue or entry.issue_type or ""),
    issue_type = tostring(entry.issue_type or entry.issue or ""),
    category = tostring(entry.category or ""),
    source = tostring(entry.source or entry["发现来源"] or "Optimization"),
    reason = tostring(entry.reason or ""),
    analysis = tostring(entry.analysis or entry["分析结果"] or ""),
    solution = tostring(entry.solution or entry["优化方案"] or ""),
    result = tostring(entry.result or entry["执行结果"] or ""),
    device = tostring(entry.device or entry["验证设备"] or ""),
    version = tostring(entry.version or entry["版本变化"] or ""),
    proposal_id = tostring(entry.proposal_id or ""),
    snapshot_id = tostring(entry.snapshot_id or ""),
    bid = tostring(entry.bid or ""),
    goal = tostring(entry.goal or ""),
    event = entry.event or "history",
  }
  append_jsonl(history_path(), row)
  append_jsonl(history_var_path(), row)
  M._last_history = row
  return row
end

function M.classify(issue)
  local Zy = _G.Zy
  if Zy and Zy.IssueClassifier and Zy.IssueClassifier.classify then
    return Zy.IssueClassifier.classify(issue)
  end
  return {
    category = "script_logic", category_zh = "脚本逻辑问题",
    module = "Script", confidence = 0.4, source = "fallback",
  }
end

--------------------------------------------------------------------------
-- cycle — 2.0 完整一轮（默认 proposal）
-- opts.human_confirm=true 才 apply；opts.legacy=true 走 1.0 直通 apply
--------------------------------------------------------------------------
function M.cycle(goal, opts)
  opts = opts or {}
  goal = tostring(goal or "opt_cycle")
  local Zy = assert(_G.Zy, "Zy required")
  local report = {
    goal = goal,
    ok = false,
    stages = {},
    mode = (opts.legacy and "legacy") or "proposal",
  }
  local function stage(name, ok, detail)
    report.stages[#report.stages + 1] = { name = name, ok = not not ok, detail = detail }
    log(string.format("Optimization.cycle [%s] ok=%s", name, tostring(ok)))
  end

  local bid = opts.bid or "com.example.app"
  local dw = tonumber(opts.design_w) or 1136
  local dh = tonumber(opts.design_h) or 640
  local device_tag = tostring(opts.device or opts.device_ip or "")

  -- collect
  local metrics = M.collect({
    bid = bid, goal = goal, design_w = dw, design_h = dh,
    path = opts.path, iter = opts.iter or 1,
    phase = opts.phase, last_ok = opts.last_ok, last_reason = opts.last_reason,
    last_error = opts.last_error, phase_unchanged_n = opts.phase_unchanged_n,
    ocr = opts.ocr, vision_hit = opts.vision_hit, vision_kind = opts.vision_kind,
    force_issue = opts.force_issue, force_reason = opts.force_reason,
    fingerprint_before = opts.fingerprint_before, fingerprint_after = opts.fingerprint_after,
    last_act = opts.last_act, shot = opts.shot,
  })
  stage("collect", true, metrics.phase)

  -- detect
  local issues = M.detect(metrics)
  stage("detect", true, tostring(#issues))
  if #issues == 0 and not opts.force_issue then
    report.ok = true
    report.note = "no_issues"
    stage("idle", true, "no_issues")
    M.recordHistory({
      module = "Optimization", issue = "none", reason = "no_issues",
      solution = "idle", device = device_tag, result = "PASS",
      goal = goal, bid = bid, event = "cycle_clean",
    })
    M._write_cycle_summary(report)
    return report
  end

  local issue = issues[1]

  -- classify (2.0)
  local classification = M.classify(issue)
  stage("classify", true, classification.category)
  report.classification = classification

  -- analyze
  local analysis = M.analyze(issue)
  stage("analyze", true, analysis.root_cause)

  -- propose
  local patch = M.propose(issue, analysis)
  stage("propose", true, patch.action)

  -- advisor → proposal（默认不 apply）
  local proposal
  if Zy.OptimizationAdvisor and Zy.OptimizationAdvisor.advise then
    proposal = Zy.OptimizationAdvisor.advise(issue, analysis, classification, patch)
  else
    proposal = {
      id = "local_" .. tostring(os.time()), status = "pending",
      action = patch.action, confirmed = false, apply_allowed = false,
      solution = tostring(patch.action), touches_core = false,
    }
  end
  stage("human_confirm", false, "pending:" .. tostring(proposal.id))
  report.proposal = proposal
  report.issue = issue
  report.analysis = analysis
  report.patch = patch

  local confirmed = opts.human_confirm == true or opts.confirmed == true
  if opts.proposal_id and Zy.OptimizationAdvisor and Zy.OptimizationAdvisor.confirm then
    local cok = Zy.OptimizationAdvisor.confirm(opts.proposal_id, true)
    confirmed = confirmed or cok
    proposal = Zy.OptimizationAdvisor.get(opts.proposal_id) or proposal
  end
  if confirmed and Zy.OptimizationAdvisor and Zy.OptimizationAdvisor.confirm then
    Zy.OptimizationAdvisor.confirm(proposal.id, true)
    proposal = Zy.OptimizationAdvisor.get(proposal.id) or proposal
  end

  -- legacy 1.0：跳过确认直接 apply（仅显式 opts.legacy）
  local may_apply = opts.legacy == true
  if not may_apply and Zy.OptimizationAdvisor and Zy.OptimizationAdvisor.canApply then
    may_apply = select(1, Zy.OptimizationAdvisor.canApply(proposal))
  elseif not may_apply then
    may_apply = proposal.confirmed and proposal.apply_allowed
  end

  if not may_apply then
    report.ok = true
    report.note = "proposal_pending_human_confirm"
    report.waiting_confirm = true
    M.recordHistory({
      module = classification.module, issue = issue.type,
      category = classification.category, source = classification.source,
      reason = analysis.root_cause, analysis = analysis.root_cause,
      solution = proposal.solution or patch.action,
      device = device_tag, result = "PENDING_CONFIRM",
      proposal_id = proposal.id, goal = goal, bid = bid,
      event = "proposal",
    })
    stage("record", true, "proposal_only")
    M._write_cycle_summary(report)
    return report
  end

  -- 已确认：snapshot → apply → verify → rollback?/commit → record
  stage("human_confirm", true, proposal.id)

  local plan = {
    goal = goal, bid = bid, design_w = dw, design_h = dh,
    phase = issue.phase or metrics.phase, path = metrics.path,
  }
  if Zy.AI and Zy.AI.plan then
    plan = Zy.AI.plan(goal, { bid = bid, phase = plan.phase or "unknown" }, {
      design_w = dw, design_h = dh, bid = bid,
    })
    plan.path = metrics.path
  end

  local snap_id
  if Zy.OptimizationRollback and Zy.OptimizationRollback.snapshot then
    snap_id = Zy.OptimizationRollback.snapshot({
      path = metrics.path or opts.path, reason = issue.type,
      goal = goal, bid = bid, version = "pre_" .. tostring(os.time()),
    })
  end
  report.snapshot_id = snap_id
  stage("snapshot", snap_id ~= nil, snap_id)

  local apply = M.apply(plan, patch, {
    bid = bid, goal = goal, design_w = dw, design_h = dh,
    path = metrics.path, reason = issue.reason, max_loop = opts.max_loop or 3,
  })
  stage("apply", apply.ok, apply.path)

  local vok, vrep = M.verify(apply.path, {
    bid = bid, goal = goal, light_test = opts.light_test ~= false, skip_test = opts.skip_test,
  })
  stage("verify", vok, vrep and vrep.forbidden and "forbidden" or (vrep and vrep.test_detail and vrep.test_detail.phase))

  if not vok and snap_id and Zy.OptimizationRollback and Zy.OptimizationRollback.auto_restore_on_fail then
    local rok, rn = Zy.OptimizationRollback.auto_restore_on_fail(snap_id, false)
    stage("rollback", rok, tostring(rn))
    report.rolled_back = rok
  end

  local ver = M.commit({
    goal = goal, bid = bid, path = apply.path, src = apply.src, ok = vok,
    issue_type = issue.type, patch_action = patch.action, phase = metrics.phase,
    metrics_summary = issue.type .. ":" .. tostring(patch.action),
    rules = table.concat(patch.expand_words or {}, ","),
  })
  stage("commit", true, ver)

  local result_str = (apply.ok and vok) and "PASS" or "FAIL"
  M.recordHistory({
    module = classification.module, issue = issue.type,
    category = classification.category, source = classification.source,
    reason = analysis.root_cause, analysis = analysis.root_cause,
    solution = proposal.solution or patch.action,
    device = device_tag, result = result_str, version = ver,
    proposal_id = proposal.id, snapshot_id = snap_id,
    goal = goal, bid = bid, event = "cycle_applied",
  })
  stage("record", true, result_str)

  report.ok = apply.ok and vok
  report.apply = apply
  report.verify = vrep
  report.version = ver
  report.path = apply.path
  M._write_cycle_summary(report)
  return report
end

function M._write_cycle_summary(report)
  local Zy = _G.Zy
  local lines = {
    "OPT_CYCLE goal=" .. tostring(report.goal),
    "ok=" .. tostring(report.ok),
    "mode=" .. tostring(report.mode),
    "path=" .. tostring(report.path),
    "version=" .. tostring(report.version),
    "proposal=" .. tostring(report.proposal and report.proposal.id),
  }
  for _, s in ipairs(report.stages or {}) do
    lines[#lines + 1] = string.format("[%s] %s", tostring(s.name), tostring(s.ok))
  end
  local body = table.concat(lines, "\n") .. "\n"
  local f = io.open(var_dir() .. "/.ziyan_opt_cycle.txt", "w")
  if f then f:write(body); f:close() end
  if Zy and Zy.File and Zy.File.write then
    pcall(Zy.File.write, Zy.File.varDir() .. "/.ziyan_opt_cycle.txt", body)
  end
end

--------------------------------------------------------------------------
-- hooks / status
--------------------------------------------------------------------------
function M.reportIssue(issue)
  issue = issue or {}
  issue.ts = os.time()
  append_jsonl(var_dir() .. "/.ziyan_opt_issues.jsonl", {
    ts = issue.ts, type = issue.type or "manual", reason = issue.reason or "",
    bid = issue.bid or "", phase = issue.phase or "", event = "hook",
  })
  if not auto_enabled(issue) and not issue.force then
    return false, "auto_opt_disabled"
  end
  return true, M.detect({
    bid = issue.bid, phase = issue.phase, last_ok = false,
    last_reason = issue.reason, force_issue = issue.type, force_reason = issue.reason,
    path = issue.path, goal = issue.goal,
  })
end

function M.status()
  return {
    version = M.version,
    model = M.model,
    last_metrics = M._last_metrics,
    last_issues = M._last_issues,
    last_patch = M._last_patch,
    last_apply = M._last_apply,
    last_verify = M._last_verify,
    last_version = M._last_version,
    last_history = M._last_history,
    history_path = history_path(),
    versions_dir = versions_dir(),
  }
end

function M.schedule(opts)
  -- 二期占位：记录调度意图
  opts = opts or {}
  append_jsonl(var_dir() .. "/.ziyan_opt_schedule.jsonl", {
    ts = os.time(), goal = opts.goal or "", bid = opts.bid or "", event = "schedule",
  })
  return true, "scheduled_noop"
end

return M
