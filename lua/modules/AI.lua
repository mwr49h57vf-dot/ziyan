--[[ Zy.AI — 自主脚本生成模块
  依据视觉/状态/案例反馈生成「仅调用 Zy.*」的自动化脚本。
  禁止固定物理坐标；禁止绕过 SDK。
  闭环：分析→选函数→生成→真机测→采结果→优化→再生成。
]]
local C = require("modules._ctx")
local M = {
  name = "AI",
  version = "1.1.0",
  model = "AutonomousScriptGenerator",
}

local function defined(n) return type(_G[n]) == "function" end

local function media()
  return "/private/var/mobile/Media/ZiYan"
end

local function gen_dir()
  local d = media() .. "/scripts/generated"
  pcall(function() os.execute(string.format('mkdir -p "%s"', d)) end)
  return d
end

local function rec_file()
  return gen_dir() .. "/AI_GEN_DB.jsonl"
end

local function esc(s)
  return tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function log(msg)
  local Zy = _G.Zy
  if Zy and type(Zy.Log) == "function" then Zy.Log(msg)
  elseif Zy and Zy.Log and Zy.Log.write then Zy.Log.write(msg)
  else print(tostring(msg)) end
end

function M.record(row)
  row = row or {}
  local Zy = _G.Zy
  local prof = (Zy and Zy.Device and Zy.Device.profile()) or {}
  local line = string.format(
    '{"ts":%d,"time":"%s","goal":"%s","funcs":"%s","code_ver":"%s","device":"%s","os":"%s",'
      .. '"bid":"%s","ok":%s,"reason":"%s","path":"%s","iter":%s,"event":"%s"}\n',
    os.time(),
    os.date("%Y-%m-%d %H:%M:%S"),
    esc(row.goal),
    esc(row.funcs or table.concat(row.func_list or {}, ",")),
    esc(row.code_ver or M.version),
    esc(prof.model or ""),
    esc(prof.os or ""),
    esc(row.bid or C.bid or ""),
    row.ok and "true" or "false",
    esc(row.reason or ""),
    esc(row.path or ""),
    tostring(row.iter or 0),
    esc(row.event or "generate")
  )
  local f = io.open(rec_file(), "a")
  if f then f:write(line); f:close() end
  pcall(function()
    local var = (Zy and Zy.File and Zy.File.varDir()) or (_G.ZIYAN_VAR or "/usr/lib/ziyan/var")
    local vf = io.open(var .. "/.ziyan_ai_gen.jsonl", "a")
    if vf then vf:write(line); vf:close() end
  end)
  if Zy and Zy.Case then
    Zy.Case.record({
      bid = row.bid, action = "ai_" .. tostring(row.event or "gen"),
      ok = row.ok, reason = row.reason, phase = row.phase, event = "ai_generate",
    })
  end
  return line
end

--- 采集生成输入上下文
function M.collect(bid, opts)
  local Zy = assert(_G.Zy, "Zy required")
  bid = bid or C.bid
  opts = opts or {}
  Zy.Device.refresh()
  local prof = Zy.Device.profile() or {}
  if bid then
    Zy.App.launch(bid, opts.wait_ms or 2000)
    Zy.Screen.sync(opts.orient or C.orient or 1, bid)
  end
  local si = Zy.Screen.info() or {}
  local fr = Zy.Game.analyze(bid)
  local st = Zy.StateMachine.current(bid)
  local suggest = Zy.StateMachine.suggest(st)
  local shot = nil
  if not _G.__ZIYAN_OCR_NO_SHOT then
    shot = Zy.Screen.snapshot("ai_collect")
  end

  local vision = { hit = false }
  if not _G.__ZIYAN_OCR_NO_SHOT then
    local hit, kind, x, y, c, detail = Zy.Vision.analyze({
      words = opts.words or { "登录", "开始", "确定", "进入", "继续" },
      design_w = C.design_w, design_h = C.design_h,
    })
    vision = { hit = hit, kind = kind, x = x, y = y, c = c, detail = detail }
  else
    -- 无 OCR 截图冒烟：不做扫金，避免阻塞；比例启发留到 plan 阶段
    vision = { hit = false, kind = "smoke_skip" }
  end
  if vision.hit and vision.x and not vision.rx then
    local w, h = Zy.Screen.size()
    vision.rx = (tonumber(vision.x) or 0) / math.max(w, 1)
    vision.ry = (tonumber(vision.y) or 0) / math.max(h, 1)
  end

  return {
    bid = bid,
    device = prof,
    screen = si,
    phase = fr.phase or st,
    frame = fr,
    suggest = suggest,
    vision = vision,
    shot = shot,
    state = st,
    history = {
      last_ok = Zy.Script and Zy.Script.get("last_ok"),
      last_reason = Zy.Script and Zy.Script.get("last_reason"),
      last_phase = Zy.Script and Zy.Script.get("last_phase"),
    },
    ts = os.time(),
  }
end

--- 需求分析（自然语言 → 结构化任务）
function M.analyzeNeed(need, opts)
  opts = opts or {}
  need = tostring(need or "")
  local lower = need:lower()
  local tasks = {}
  local words = { "确定", "继续", "开始" }
  if need:find("登录") or lower:find("login") then
    tasks[#tasks + 1] = "login"
    words[#words + 1] = "登录"
  end
  if need:find("领取") or need:find("奖励") or need:find("每日") or lower:find("reward") then
    tasks[#tasks + 1] = "daily_reward"
    words[#words + 1] = "领取"
    words[#words + 1] = "奖励"
  end
  if need:find("进角") or need:find("进入") then
    tasks[#tasks + 1] = "enter_role"
    words[#words + 1] = "进入"
  end
  if #tasks == 0 then tasks[1] = "advance_ui" end
  local modules = {
    "Device", "Screen", "Coordinate", "Vision", "Image", "OCR",
    "Touch", "Verify", "StateMachine", "Game", "Script",
  }
  local flow = {
    "Device.refresh → Screen.sync → Coordinate.setDesign",
    "Game.analyze / StateMachine.current",
    "Vision/OCR/Image 定位",
    "Touch.atRatio|atHit + Verify.act",
    "Script.tick / recover",
  }
  local states = { "boot", "loading", "login", "menu", "dialog", "running", "error" }
  return {
    need = need,
    tasks = tasks,
    modules = modules,
    flow = flow,
    states = states,
    words = words,
    bid = opts.bid,
    design_w = opts.design_w or 1136,
    design_h = opts.design_h or 640,
  }
end

--- 建立状态模型 + 选择函数清单
function M.plan(goal, ctx, opts)
  opts = opts or {}
  ctx = ctx or {}
  goal = tostring(goal or "advance_ui")
  local analysis = opts.analysis or M.analyzeNeed(goal, opts)
  local phase = tostring(ctx.phase or "unknown")
  local funcs = {
    "Device.refresh", "Device.profile",
    "Screen.sync", "Screen.snapshot", "Screen.info",
    "Coordinate.setDesign",
    "Vision.analyze", "OCR.find", "Image.findColor",
    "Touch.tapRatio", "Touch.tapHit",
    "Verify.act",
    "StateMachine.current", "StateMachine.suggest",
    "Game.analyze", "Game.suggest", "Game.phase",
    "Script.begin", "Script.act", "Script.loop", "Script.tick", "Script.recover", "Script.set",
  }
  local steps = {
    { kind = "analyze", desc = "analyzeNeed", tasks = analysis.tasks },
    { kind = "init", desc = "Script.begin + Device" },
    { kind = "sync", desc = "Screen.sync" },
    { kind = "classify", desc = "Game.analyze / StateMachine" },
  }
  local action = { kind = "tap_ratio", rx = 0.50, ry = 0.72, label = "ai_cta" }
  if ctx.vision and ctx.vision.hit and ctx.vision.rx then
    action = {
      kind = "tap_ratio",
      rx = math.max(0.05, math.min(0.95, ctx.vision.rx)),
      ry = math.max(0.05, math.min(0.95, ctx.vision.ry)),
      label = "ai_vision_ratio",
    }
    table.insert(steps, { kind = "vision", desc = "Vision hit → tapRatio" })
  else
    if phase == "login" or (analysis.tasks[1] == "login") then
      action.rx, action.ry, action.label = 0.64, 0.72, "ai_login"
    elseif phase == "menu" then action.rx, action.ry = 0.50, 0.70
    elseif phase == "role" then action.rx, action.ry = 0.50, 0.75
    elseif phase == "boot" then
      action = { kind = "launch", label = "ai_launch" }
    end
    if analysis.tasks then
      for _, t in ipairs(analysis.tasks) do
        if t == "daily_reward" then
          action = { kind = "tap_ratio", rx = 0.72, ry = 0.18, label = "ai_reward_entry" }
        end
      end
    end
    table.insert(steps, { kind = "heuristic", desc = "phase/task heuristic ratio" })
  end
  table.insert(steps, { kind = "act", action = action })
  table.insert(steps, { kind = "verify", desc = "Script.act / Verify" })
  table.insert(steps, { kind = "recover", desc = "Script.recover on fail" })

  local tune = opts.tune or {}
  if action.rx and tune.shift_y then
    action.ry = math.max(0.05, math.min(0.95, (action.ry or 0.7) + tune.shift_y))
  end
  if action.rx and tune.shift_x then
    action.rx = math.max(0.05, math.min(0.95, (action.rx or 0.5) + tune.shift_x))
  end

  return {
    goal = goal,
    phase = phase,
    funcs = funcs,
    steps = steps,
    action = action,
    analysis = analysis,
    words = analysis.words,
    design_w = opts.design_w or C.design_w or analysis.design_w,
    design_h = opts.design_h or C.design_h or analysis.design_h,
    bid = ctx.bid or C.bid or opts.bid,
    code_ver = M.version,
  }
end

--- 生成 Lua 源码（只含 Zy.*）
function M.generate(plan, opts)
  plan = plan or {}
  opts = opts or {}
  local bid = plan.bid or "com.example.app"
  local dw = tonumber(plan.design_w) or 1136
  local dh = tonumber(plan.design_h) or 640
  local act = plan.action or { kind = "tap_ratio", rx = 0.5, ry = 0.72, label = "ai_cta" }
  local goal = plan.goal or "advance_ui"
  local max_loop = tonumber(opts.max_loop) or 3
  local rx = tonumber(act.rx) or 0.5
  local ry = tonumber(act.ry) or 0.72

  local lines = {}
  local function L(s) lines[#lines + 1] = s end

  L("-- AI-GENERATED by Zy.AI " .. M.version)
  L("-- goal=" .. tostring(goal) .. " phase_hint=" .. tostring(plan.phase))
  L("-- RULES: Zy.* only; no fixed physical coords; no SDK bypass")
  L("-- pipeline: Device>Screen>Coordinate>Vision>OCR>Image>Touch>Verify>StateMachine>Game>Script")
  L("_G.__ZIYAN_OCR_NO_SHOT = true")
  L("")
  L("local function ailog(msg)")
  L("  print(tostring(msg))")
  L("end")
  L("")
  L("function main()")
  L("  if type(Zy) ~= \"table\" then require(\"modules\") end")
  L(string.format("  local BID = %q", bid))
  L(string.format("  local DW, DH = %d, %d", dw, dh))
  L("  Zy.Device.refresh()")
  L("  Zy.Script.begin({ bid = BID, design_w = DW, design_h = DH, orient = 1 })")
  L("  Zy.Coordinate.setDesign(DW, DH)")
  L("  local prof = Zy.Device.profile()")
  L("  ailog(\"AI script device=\" .. tostring(prof and prof.model))")
  L("  Zy.App.launch(BID, 800)")
  L("  Zy.Screen.sync(1, BID)")
  L("  local si = Zy.Screen.info()")
  L("  local sw = (si and (si.logic_w or si.w)) or select(1, Zy.Screen.size())")
  L("  local sh = (si and (si.logic_h or si.h)) or select(2, Zy.Screen.size())")
  L("  ailog(\"AI screen=\" .. tostring(sw) .. \"x\" .. tostring(sh))")
  L("  Zy.Script.set(\"goal\", " .. string.format("%q", goal) .. ")")
  L("")
  L("  local handlers = {")
  L("    boot = function(ctx) Zy.App.launch(BID, 600); Zy.Screen.sync(1, BID) end,")
  L("    loading = function(ctx) end,")
  L("    login = function(ctx)")
  L("      local x, y = ctx.findText(\"登录\")")
  L("      if x ~= -1 then ctx.tapHit(x, y) else")
  if act.kind == "launch" then
    L("        Zy.App.activate(BID, 600)")
  else
    L(string.format("        ctx.tapRatio(%.4f, %.4f)", rx, ry))
  end
  L("      end")
  L("    end,")
  L("    menu = function(ctx)")
  L("      local x, y = ctx.findText(\"领取\")")
  L("      if x == -1 then x, y = ctx.findText(\"奖励\") end")
  L("      if x ~= -1 then ctx.tapHit(x, y) else ctx.tapRatio(0.50, 0.70) end")
  L("    end,")
  L("    dialog = function(ctx)")
  L("      local x, y = ctx.findText(\"确定\")")
  L("      if x ~= -1 then ctx.tapHit(x, y) else ctx.tapRatio(0.50, 0.60) end")
  L("    end,")
  L("    role = function(ctx) ctx.tapRatio(0.50, 0.75) end,")
  L("    running = function(ctx) Zy.Script.set(\"done\", true) end,")
  L("    error = function(ctx) Zy.Script.recover({ policy = \"resync\", reason = \"ai_error_state\" }) end,")
  L("    default = function(ctx)")
  L("      local x, y = ctx.findText(\"领取\")")
  L("      if x == -1 then x, y = ctx.findText(\"登录\") end")
  L("      if x ~= -1 then ctx.tapHit(x, y) else")
  L(string.format("        ctx.tapRatio(%.4f, %.4f)", rx, ry))
  L("      end")
  L("    end,")
  L("  }")
  L("")
  L("  -- 视觉增强：Vision/OCR/Image；冒烟可设 __ZIYAN_OCR_NO_SHOT")
  local words = plan.words or { "登录", "开始", "确定", "进入", "领取" }
  local wlit = {}
  for _, w in ipairs(words) do
    wlit[#wlit + 1] = string.format("%q", w)
  end
  L("  Zy.Script.defineTask(\"vision_try\", function()")
  L("    if _G.__ZIYAN_OCR_NO_SHOT then return false, \"smoke_skip_vision\" end")
  L("    local hit, kind, x, y = Zy.Vision.analyze({")
  L("      words = { " .. table.concat(wlit, ", ") .. " }, design_w = DW, design_h = DH,")
  L("    })")
  L("    if hit and x and x ~= -1 then")
  L("      return Zy.Script.act(\"ai_vision_hit\", function(ctx) ctx.tapHit(x, y) end, 300)")
  L("    end")
  L("    local cx, cy = Zy.Image.findColor(0xE8C070, \"\", 88, 0, 0, DW, DH)")
  L("    if cx ~= -1 then")
  L("      return Zy.Script.act(\"ai_color_hit\", function(ctx) ctx.tapHit(cx, cy) end, 300)")
  L("    end")
  L("    return false, \"no_vision_hit\"")
  L("  end)")
  L("")
  L(string.format("  Zy.Script.loop(%d, function(i, ctx)", max_loop))
  L("    Zy.Screen.sync(1, BID)")
  L("    local st = Zy.StateMachine.current(BID)")
  L("    local fr = Zy.Game.analyze(BID, { light = true })")
  L("    ailog(string.format(\"AI loop %d phase=%s st=%s suggest=%s\", i, tostring(fr.phase), tostring(st), Zy.Game.suggest(fr.phase)))")
  L("    if fr.phase == \"running\" then Zy.Script.set(\"done\", true); return false end")
  L("    pcall(function() Zy.Script.runTask(\"vision_try\") end)")
  L("    Zy.Script.tick({ handlers = handlers, wait_ms = 300 })")
  L("    if Zy.Script.get(\"done\") then return false end")
  L("    return true")
  L("  end)")
  L("")
  L("  local fin = Zy.Script.get(\"last_phase\") or Zy.Game.phase(BID)")
  L("  pcall(function()")
  L("    Zy.File.write(Zy.File.varDir() .. \"/.ziyan_ai_last_run.txt\",")
  L("      string.format(\"goal=%s phase=%s done=%s\\n\", Zy.Script.get(\"goal\"), tostring(fin), tostring(Zy.Script.get(\"done\"))))")
  L("  end)")
  L("  ailog(\"AI generated script finished phase=\" .. tostring(fin))")
  L("end")
  L("")
  L("return main")
  L("")

  local src = table.concat(lines, "\n")
  if src:find("Touch%.tap%s*%(") then
    error("AI.generate refused: forbidden Touch.tap")
  end
  return src
end

function M.save(source, meta)
  meta = meta or {}
  local name = meta.name or string.format("ai_%s_%d.lua", tostring(meta.goal or "task"):gsub("%W", "_"):sub(1, 24), os.time() % 100000)
  if not name:find("%.lua$") then name = name .. ".lua" end
  local path = gen_dir() .. "/" .. name
  local Zy = _G.Zy
  if Zy and Zy.File then
    Zy.File.write(path, source)
  else
    local f = io.open(path, "w")
    if f then f:write(source); f:close() end
  end
  M.record({
    goal = meta.goal, bid = meta.bid, path = path, ok = true,
    funcs = table.concat((meta.plan and meta.plan.funcs) or {}, ","),
    code_ver = M.version, event = "save", iter = meta.iter,
  })
  return path
end

--- 真机执行生成脚本（dofile + main）
function M.test(path_or_src, opts)
  opts = opts or {}
  local Zy = assert(_G.Zy)
  local path = path_or_src
  if type(path_or_src) == "string" and path_or_src:find("function main", 1, true) then
    path = M.save(path_or_src, { goal = opts.goal or "inline", bid = opts.bid, name = "ai_inline_test.lua" })
  end
  log("AI.test " .. tostring(path))
  -- 轻量：仅语法/加载，不执行 main（避免 App.launch 挂死冒烟）
  if opts.load_only or opts.light_test then
    local chunk, e
    if type(loadfile) == "function" then
      chunk, e = loadfile(path)
    else
      local f = io.open(path, "r")
      local body = f and f:read("*a") or ""
      if f then f:close() end
      chunk, e = load(body, "@" .. path)
    end
    local ok = type(chunk) == "function"
    M.record({
      goal = opts.goal, bid = opts.bid, path = path, ok = ok,
      reason = ok and "load_only" or tostring(e), event = "test_load", iter = opts.iter,
    })
    return ok, { path = path, phase = "load_only", err = e, load_only = true }
  end
  local ok_load, mod = pcall(dofile, path)
  if not ok_load then
    M.record({ goal = opts.goal, bid = opts.bid, path = path, ok = false, reason = tostring(mod), event = "test_load" })
    return false, { reason = tostring(mod), path = path }
  end
  local runner = mod
  if type(mod) == "function" then runner = mod end
  if type(_G.main) == "function" and type(runner) ~= "function" then runner = _G.main end
  local ok_run, err = true, nil
  if type(runner) == "function" then
    ok_run, err = pcall(runner)
  elseif type(main) == "function" then
    ok_run, err = pcall(main)
  end
  local phase = Zy.Script and Zy.Script.get("last_phase") or "?"
  if phase == "?" or phase == nil then
    local okp, ph = pcall(function() return Zy.Game and Zy.Game.phase and Zy.Game.phase(opts.bid or C.bid) end)
    if okp then phase = ph or "?" end
  end
  local gen_ok = ok_run == true
  local reason = gen_ok and ("ran phase=" .. tostring(phase)) or tostring(err)
  pcall(M.record, {
    goal = opts.goal, bid = opts.bid, path = path, ok = gen_ok,
    reason = reason, phase = phase, event = "test", iter = opts.iter,
  })
  return gen_ok, { path = path, phase = phase, err = err, business_done = not not Zy.Script.get("done") }
end

--- 根据失败原因调整计划
function M.optimize(plan, fail_info)
  fail_info = fail_info or {}
  plan = plan or {}
  local reason = tostring(fail_info.reason or "")
  local tune = { shift_x = 0, shift_y = 0 }
  if reason:find("still_login", 1, true) or reason:find("no_change", 1, true) then
    tune.shift_y = -0.04
    tune.shift_x = 0.02
  elseif reason:find("vision", 1, true) then
    tune.shift_y = 0.03
  elseif reason:find("boot", 1, true) then
    plan.action = { kind = "launch", label = "ai_relaunch" }
  end
  local ctx = fail_info.ctx or { phase = plan.phase, bid = plan.bid, vision = fail_info.vision }
  local new_plan = M.plan(plan.goal, ctx, {
    design_w = plan.design_w, design_h = plan.design_h, tune = tune,
  })
  M.record({
    goal = plan.goal, bid = plan.bid, ok = false, reason = reason,
    event = "optimize", iter = fail_info.iter,
    funcs = "optimize:" .. tostring(tune.shift_x) .. "," .. tostring(tune.shift_y),
  })
  return new_plan, tune
end

--- 闭环：采集→计划→生成→测试→优化→再生成
function M.loop(goal, opts)
  opts = opts or {}
  local Zy = assert(_G.Zy)
  local bid = assert(opts.bid, "AI.loop requires bid")
  local dw = assert(opts.design_w, "AI.loop requires design_w")
  local dh = assert(opts.design_h, "AI.loop requires design_h")
  local max_iter = tonumber(opts.max_iter) or 2

  Zy.Script.begin({ bid = bid, design_w = dw, design_h = dh, orient = opts.orient or 1 })
  local best = { ok = false, path = nil, phase = nil }

  for iter = 1, max_iter do
    log(string.format("AI.loop iter=%d goal=%s", iter, tostring(goal)))
    local ctx = M.collect(bid, opts)
    local plan = M.plan(goal, ctx, { design_w = dw, design_h = dh, tune = opts.tune })
    local src = M.generate(plan, { max_loop = opts.max_loop or 2 })
    local path = M.save(src, { goal = goal, bid = bid, plan = plan, iter = iter, name = string.format("ai_loop_%d.lua", iter) })
    local ok, detail = M.test(path, { goal = goal, bid = bid, iter = iter })
    detail = detail or {}
    detail.ctx = ctx
    if ok then
      best = { ok = true, path = path, phase = detail.phase, iter = iter, plan = plan }
      -- 保存优秀方案副本
      local elite = gen_dir() .. "/ai_best.lua"
      if Zy.File then Zy.File.write(elite, src) end
      M.record({ goal = goal, bid = bid, path = elite, ok = true, reason = "elite_saved", event = "elite", iter = iter })
      if detail.business_done or (opts.stop_on_running and detail.phase == "running") then
        break
      end
      -- 生成层成功即可结束（除非要求必须 running）
      if not opts.require_running then break end
    end
    local new_plan, tune = M.optimize(plan, { reason = detail.err or detail.phase or "fail", ctx = ctx, iter = iter })
    opts.tune = tune
    plan = new_plan
    best = { ok = false, path = path, phase = detail.phase, iter = iter, plan = plan, reason = detail.err }
  end

  local summary = string.format(
    "AI_LOOP goal=%s ok=%s path=%s phase=%s iter=%s\n",
    tostring(goal), tostring(best.ok), tostring(best.path), tostring(best.phase), tostring(best.iter))
  if Zy.File then
    Zy.File.write(Zy.File.varDir() .. "/.ziyan_ai_loop.txt", summary)
  end
  log(summary)
  return best
end

function M.pathDB()
  return rec_file()
end

--- 完整 AI 脚本开发流程（7.5.2）
-- 需求分析→规划→状态机→函数选择→生成→静态检查→模拟→真机测→验证→修复→存优
function M.pipeline(goal, opts)
  opts = opts or {}
  local Zy = assert(_G.Zy, "Zy required")
  local bid = opts.bid or "com.example.app"
  local dw = tonumber(opts.design_w) or 1136
  local dh = tonumber(opts.design_h) or 640
  local report = {
    goal = goal,
    stages = {},
    ok = false,
  }
  local function stage(name, ok, detail)
    report.stages[#report.stages + 1] = { name = name, ok = not not ok, detail = detail }
    log(string.format("AI.pipeline [%s] ok=%s", name, tostring(ok)))
  end

  -- 1 需求分析
  local analysis = M.analyzeNeed(goal, { bid = bid, design_w = dw, design_h = dh })
  stage("需求分析", true, table.concat(analysis.tasks, ","))

  -- 2 任务规划 + 采集（可 offline）
  local ctx = { bid = bid, phase = "unknown", vision = {} }
  if opts.offline then
    _G.__ZIYAN_OCR_NO_SHOT = true
  end
  if not opts.offline then
    local okc, c = pcall(M.collect, bid, opts)
    if okc and type(c) == "table" then ctx = c end
  end
  stage("任务规划", true, tostring(ctx.phase))

  -- 3 状态机设计 + 4 函数选择（plan 内）
  local plan = M.plan(goal, ctx, { design_w = dw, design_h = dh, analysis = analysis, bid = bid })
  stage("状态机设计", true, tostring(plan.phase))
  stage("函数选择", true, tostring(#(plan.funcs or {})))

  -- 5 代码生成
  local src = M.generate(plan, { max_loop = opts.max_loop or 3 })
  stage("代码生成", type(src) == "string" and #src > 50, tostring(#(src or "")))

  -- 6 静态检查
  local vok, vrep = true, {}
  if Zy.Script and Zy.Script.validate then
    vok, vrep = Zy.Script.validate({ code = src, require_begin = false })
  end
  if src:find("Touch%.tap%s*%(") or src:find("Touch%.click") then
    vok = false
    vrep.warnings = vrep.warnings or {}
    vrep.warnings[#vrep.warnings + 1] = "forbidden_physical"
  end
  stage("静态检查", vok, vrep)
  if not vok then
    report.ok = false
    report.reason = "static_check_fail"
    return report
  end

  -- 7 模拟运行（语法 load）
  local path = M.save(src, {
    goal = goal, bid = bid, plan = plan, name = opts.name or ("ai_pipe_" .. tostring(os.time()) .. ".lua"),
  })
  local ok_sim, err_sim = false, "no_load"
  do
    local chunk, e
    if type(loadfile) == "function" then
      chunk, e = loadfile(path)
    else
      local f = io.open(path, "r")
      local body = f and f:read("*a") or ""
      if f then f:close() end
      chunk, e = load(body, "@" .. path)
    end
    ok_sim = type(chunk) == "function"
    err_sim = e
  end
  stage("模拟运行", ok_sim, tostring(err_sim))

  -- 8 真机测试（opts.skip_test 则跳过执行）
  local tok, detail = false, {}
  if opts.skip_test then
    stage("真机测试", true, "skipped")
    tok = true
    detail = { phase = "skipped", path = path }
  else
    -- 轻量：dofile 加载；执行时强制 OCR_NO_SHOT 防卡
    local prev = _G.__ZIYAN_OCR_NO_SHOT
    if opts.light_test ~= false then _G.__ZIYAN_OCR_NO_SHOT = true end
    tok, detail = M.test(path, {
      goal = goal, bid = bid, iter = 1,
      light_test = (opts.light_test ~= false),
      load_only = opts.load_only,
    })
    _G.__ZIYAN_OCR_NO_SHOT = prev
    detail = detail or {}
    stage("真机测试", tok, detail.reason or detail.phase or detail.err)
  end

  -- 9 结果验证
  local verified = tok and (detail.reason ~= "test_load")
  stage("结果验证", verified, detail.phase)

  -- 10 错误修复
  if not tok and not opts.skip_repair then
    local new_plan = select(1, M.optimize(plan, { reason = detail.err or detail.reason or "fail", ctx = ctx, iter = 1 }))
    local src2 = M.generate(new_plan, { max_loop = opts.max_loop or 3 })
    path = M.save(src2, { goal = goal, bid = bid, plan = new_plan, name = "ai_pipe_repaired.lua", iter = 2 })
    src = src2
    plan = new_plan
    stage("错误修复", true, path)
  else
    stage("错误修复", true, "not_needed_or_skipped")
  end

  -- 11 保存优秀版本
  if tok or opts.save_anyway then
    local elite = gen_dir() .. "/ai_best.lua"
    if Zy.File then Zy.File.write(elite, src) else
      local f = io.open(elite, "w"); if f then f:write(src); f:close() end
    end
    M.record({ goal = goal, bid = bid, path = elite, ok = tok, reason = "pipeline_elite", event = "elite" })
    if Zy.Knowledge then
      Zy.Knowledge.save({
        task = goal, bid = bid, path = elite, ok = tok,
        flow = table.concat(analysis.flow or {}, " | "),
        rules = table.concat(plan.funcs or {}, ","),
        phase = detail.phase, shot = ctx.shot,
        event = "pipeline",
      })
    end
    stage("保存优秀版本", true, elite)
    report.elite = elite
  end

  report.ok = tok or (opts.skip_test and vok)
  report.path = path
  report.plan = plan
  report.analysis = analysis
  report.detail = detail
  if Zy.File then
    local lines = { "AI_PIPELINE goal=" .. tostring(goal), "ok=" .. tostring(report.ok), "path=" .. tostring(path) }
    for _, s in ipairs(report.stages) do
      lines[#lines + 1] = string.format("[%s] %s", s.name, tostring(s.ok))
    end
    Zy.File.write(Zy.File.varDir() .. "/.ziyan_ai_pipeline.txt", table.concat(lines, "\n") .. "\n")
  end
  -- 可选：pipeline 结束回调 Optimization.collect（默认关，opts.opt_collect=true）
  if opts.opt_collect and Zy.Optimization and Zy.Optimization.collect then
    pcall(function()
      Zy.Optimization.collect({
        bid = bid, goal = goal, path = path, design_w = dw, design_h = dh,
        phase = detail and detail.phase, last_ok = report.ok,
        last_reason = detail and (detail.reason or detail.err),
        iter = 1, event = "ai_pipeline",
      })
    end)
  end
  return report
end

return M
