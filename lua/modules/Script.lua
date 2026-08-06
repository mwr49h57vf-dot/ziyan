--[[ Zy.Script — 自动化脚本开发层（平台能力）
  变量 / 条件 / 循环 / 状态切换 / 任务流 / 异常恢复
  脚本必须只调 Zy.*，禁止固定坐标与录制式直控。
]]
local C = require("modules._ctx")
local M = {
  name = "Script",
  version = "2.2.0",
  layer = "script_runtime_sdk",
}

M._vars = {}
M._tasks = {}
M._running = false
M._last_error = nil

local function defined(n) return type(_G[n]) == "function" end

function M.assertPlatform()
  if type(_G.Zy) ~= "table" then
    error("ZiYan modules not loaded — require('modules') first", 2)
  end
  return true
end

local function log(msg)
  local Zy = _G.Zy
  if Zy and Zy.Log then
    if type(Zy.Log) == "function" then Zy.Log(msg)
    elseif type(Zy.Log.write) == "function" then Zy.Log.write(msg) end
  else
    print(tostring(msg))
  end
end

--------------------------------------------------------------------------
-- 变量管理
--------------------------------------------------------------------------
function M.set(key, value)
  M._vars[tostring(key)] = value
  return value
end

function M.get(key, default)
  local k = tostring(key)
  if M._vars[k] == nil then return default end
  return M._vars[k]
end

function M.has(key)
  return M._vars[tostring(key)] ~= nil
end

function M.clearVars()
  M._vars = {}
end

function M.vars()
  return M._vars
end

--------------------------------------------------------------------------
-- 会话：Device→Screen→Coordinate
--------------------------------------------------------------------------
function M.begin(opts)
  M.assertPlatform()
  opts = opts or {}
  C.reset()
  M._last_error = nil
  local Zy = _G.Zy
  local prof = Zy.Device.refresh()
  M.set("device_model", prof and prof.model)
  M.set("dpi", prof and prof.dpi)
  if opts.bid then
    C.set_bid(opts.bid)
    M.set("bid", opts.bid)
  end
  C.orient = tonumber(opts.orient) or 1
  M.set("orient", C.orient)
  Zy.Screen.sync(C.orient, opts.bid)
  if opts.design_w and opts.design_h then
    Zy.Coordinate.setDesign(opts.design_w, opts.design_h)
    M.set("design_w", opts.design_w)
    M.set("design_h", opts.design_h)
  else
    error("Zy.Script.begin requires design_w, design_h (no fixed physical coords)", 2)
  end
  M.set("started_at", os.time())
  log("Script.begin bid=" .. tostring(opts.bid))
  return Zy
end

--- 标准一步管道上下文（禁止裸 tap）
local function make_ctx(Zy)
  return {
    tapDesign = function(dx, dy, hold) return Zy.Touch.tapDesign(dx, dy, hold) end,
    tapRatio = function(rx, ry, hold) return Zy.Touch.tapRatio(rx, ry, hold) end,
    tapHit = function(lx, ly, hold) return Zy.Touch.tapHit(lx, ly, hold) end,
    findText = function(word, x1, y1, x2, y2) return Zy.OCR.find(word, x1, y1, x2, y2) end,
    findColor = function(...) return Zy.Image.findColor(...) end,
    findImage = function(...) return Zy.Image.find(...) end,
    colorAt = function(dx, dy) return Zy.Image.colorAtDesign(dx, dy) end,
    snapshot = function(tag) return Zy.Screen.snapshot(tag) end,
    phase = function() return Zy.Game.phase() end,
    classify = function() return Zy.Game.analyze() end,
    app = function() return Zy.App.windowState() end,
    suggest = function(st) return Zy.StateMachine.suggest(st or Zy.Game.phase()) end,
    var = function(k, d) return M.get(k, d) end,
    set = function(k, v) return M.set(k, v) end,
  }
end

--- 执行并验证（管道核心）
function M.act(label, fn, wait_ms)
  M.assertPlatform()
  local Zy = _G.Zy
  C.require_pipeline("verify")
  local ctx = make_ctx(Zy)
  local ok, after, reason = Zy.Verify.act(label, function()
    if type(fn) == "function" then fn(ctx) end
  end, wait_ms)
  M.set("last_act", label)
  M.set("last_ok", ok)
  M.set("last_reason", reason)
  M.set("last_phase", after and after.phase)
  if Zy.Case then
    Zy.Case.record({
      bid = C.bid, action = label, ok = ok,
      phase = after and after.phase, reason = reason, event = "script_act",
    })
  end
  return ok, after, reason
end

--------------------------------------------------------------------------
-- 条件判断 / 循环 / 状态切换
--------------------------------------------------------------------------
--- 若 pred() 为真则执行 fn（可包 Verify）
function M.when(pred, fn, label, wait_ms)
  M.assertPlatform()
  local ok_pred = false
  if type(pred) == "function" then
    ok_pred = not not pred(make_ctx(_G.Zy))
  else
    ok_pred = not not pred
  end
  M.set("last_when", ok_pred)
  if not ok_pred then return false, nil, "pred_false" end
  if label then
    return M.act(label, fn, wait_ms)
  end
  if type(fn) == "function" then fn(make_ctx(_G.Zy)) end
  return true
end

--- 循环：最多 max_times；body 返回 false 可提前停
function M.loop(max_times, body)
  M.assertPlatform()
  max_times = tonumber(max_times) or 1
  local n = 0
  for i = 1, max_times do
    n = i
    M.set("loop_i", i)
    local cont = true
    if type(body) == "function" then
      local r = body(i, make_ctx(_G.Zy))
      if r == false then cont = false end
    end
    if not cont then break end
  end
  M.set("loop_done", n)
  return n
end

--- 直到状态命中或超时
function M.untilPhase(target, timeout_ms, interval_ms)
  M.assertPlatform()
  local Zy = _G.Zy
  target = tostring(target or "running")
  timeout_ms = tonumber(timeout_ms) or 15000
  interval_ms = tonumber(interval_ms) or 800
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < timeout_ms do
    Zy.Screen.sync(C.orient, C.bid)
    local st = Zy.Game.phase(C.bid)
    M.set("phase", st)
    if st == target then return true, st end
    if defined("mSleep") then mSleep(interval_ms) end
  end
  return false, Zy.Game.phase(C.bid)
end

--- 状态切换建议并可选执行一步
function M.stepState(handlers, wait_ms)
  M.assertPlatform()
  local Zy = _G.Zy
  return Zy.StateMachine.step(C.bid, handlers, wait_ms)
end

--------------------------------------------------------------------------
-- 任务流程管理
--------------------------------------------------------------------------
function M.defineTask(name, fn)
  M._tasks[tostring(name)] = fn
end

function M.runTask(name, ...)
  M.assertPlatform()
  local fn = M._tasks[tostring(name)]
  if type(fn) ~= "function" then
    M._last_error = "no_task:" .. tostring(name)
    return false, M._last_error
  end
  local ok, a, b, c = pcall(fn, ...)
  if not ok then
    M._last_error = tostring(a)
    log("task fail " .. tostring(name) .. " " .. M._last_error)
    return false, M._last_error
  end
  return a, b, c
end

function M.runTasks(names)
  local results = {}
  for _, name in ipairs(names or {}) do
    local ok, err = M.runTask(name)
    results[#results + 1] = { name = name, ok = not not ok, err = err }
    if not ok then break end
  end
  M.set("task_results", results)
  return results
end

--------------------------------------------------------------------------
-- 标准执行流 + 异常恢复
--------------------------------------------------------------------------
--- 完整一轮：识别状态→建议→动作→验证→记录
function M.tick(opts)
  M.assertPlatform()
  opts = opts or {}
  local Zy = _G.Zy
  Zy.Screen.sync(C.orient, C.bid)
  local fr = Zy.Game.analyze(C.bid, { light = not not _G.__ZIYAN_OCR_NO_SHOT })
  M.set("phase", fr.phase)
  local suggest = Zy.StateMachine.suggest(fr.phase)
  M.set("suggest", suggest)
  log(string.format("tick phase=%s suggest=%s", tostring(fr.phase), tostring(suggest)))

  local handler = opts.handlers and (opts.handlers[fr.phase] or opts.handlers.default)
  if type(handler) ~= "function" and type(opts.on_tick) == "function" then
    handler = opts.on_tick
  end
  if type(handler) ~= "function" then
    return false, fr, "no_handler"
  end
  local ok, after, reason = M.act(suggest, function(ctx)
    handler(ctx, fr)
  end, opts.wait_ms)
  if not ok then
    M.recover({ phase = fr.phase, reason = reason, frame = after or fr })
    -- 可选优化钩子（默认关）：opt_hook / auto_opt
    if M.get("opt_hook") or M.get("auto_opt") or opts.opt_hook then
      pcall(function()
        local Opt = Zy.Optimization
        if Opt and Opt.reportIssue then
          Opt.reportIssue({
            type = "verify_fail",
            reason = tostring(reason or "tick_fail"),
            bid = C.bid,
            phase = fr.phase,
            auto_opt = M.get("auto_opt") == true,
            force = false,
          })
        end
      end)
    end
  end
  return ok, after or fr, reason
end

--- 异常恢复：诊断 + 可选重开 App + 再同步
function M.recover(info)
  M.assertPlatform()
  info = info or {}
  local Zy = _G.Zy
  M._last_error = info.reason or info.err or "recover"
  log("recover: " .. tostring(M._last_error))
  if Zy.Diagnose and info.frame then
    Zy.Diagnose.onStuck(info.frame, info.reason or "recover")
  elseif Zy.Verify then
    Zy.Verify.failReport({
      bid = C.bid, phase = info.phase,
      reason = tostring(M._last_error),
      module = "Script.recover",
      fix = "relaunch / resync / reclassify",
      tag = "script_recover",
    })
  end
  -- 可选优化钩子（默认关）
  if M.get("opt_hook") or M.get("auto_opt") or info.opt_hook then
    pcall(function()
      local Opt = Zy.Optimization
      if Opt and Opt.reportIssue then
        Opt.reportIssue({
          type = "crash",
          reason = tostring(M._last_error),
          bid = C.bid,
          phase = info.phase,
          auto_opt = M.get("auto_opt") == true,
          force = false,
        })
      end
    end)
  end
  local policy = info.policy or M.get("recover_policy", "resync")
  if policy == "relaunch" and Zy.App and C.bid then
    Zy.App.close(C.bid)
    if defined("mSleep") then mSleep(800) end
    Zy.App.launch(C.bid, 2500)
  end
  Zy.Screen.sync(C.orient, C.bid)
  return true
end

function M.lastError()
  return M._last_error
end

--------------------------------------------------------------------------
-- 加载 / 路径
--------------------------------------------------------------------------
function M.scriptsDir()
  local base = _G.ZIYAN_SCRIPTS or "/private/var/mobile/Media/ZiYan"
  return base .. "/scripts"
end

function M.load(path)
  M.assertPlatform()
  return dofile(path)
end

--- 运行 scripts/ 下相对路径
function M.run(rel)
  M.assertPlatform()
  local path = rel
  if not rel:find("^/") then
    path = M.scriptsDir() .. "/" .. rel
  end
  log("Script.run " .. path)
  return dofile(path)
end

--- 结束脚本会话（兼容 TS luaExit 思想；不杀进程）
function M.exit(reason)
  M.set("exit_reason", reason or "script_exit")
  M.set("exited", true)
  log("Script.exit " .. tostring(reason))
  return true
end

--- 请求重启当前入口脚本（由调度层读取标志）
function M.restart(reason)
  M.set("restart_requested", true)
  M.set("restart_reason", reason or "script_restart")
  log("Script.restart " .. tostring(reason))
  local Zy = _G.Zy
  if Zy and Zy.File then
    pcall(function()
      Zy.File.write(Zy.File.varDir() .. "/.ziyan_restart_req", tostring(reason or "1") .. "\n")
    end)
  end
  return true
end

--------------------------------------------------------------------------
-- SDK：generate / AI 打通 / debug / validate（阶段 7.35 + 7.5）
--------------------------------------------------------------------------
local function sdk_root()
  local cands = {
    "/Users/mac/Desktop/ZiYan_副本/Script",
    "/private/var/mobile/Media/ZiYan/Script",
    (_G.ZIYAN_SCRIPTS or "/private/var/mobile/Media/ZiYan") .. "/Script",
  }
  for _, p in ipairs(cands) do
    local f = io.open(p .. "/README.md", "r")
    if f then f:close(); return p end
  end
  return cands[3]
end

local function read_template(name)
  local path = sdk_root() .. "/Template/" .. name .. ".lua"
  local f = io.open(path, "r")
  if not f then return nil, path end
  local body = f:read("*a"); f:close()
  return body, path
end

local function write_out(body, opts, tag)
  local out = opts.out
  if not out or out == "" then
    local dir = M.scriptsDir() .. "/generated"
    pcall(function() os.execute('mkdir -p "' .. dir .. '"') end)
    out = dir .. "/" .. (tag or "gen") .. "_" .. tostring(os.time()) .. ".lua"
  end
  local Zy = _G.Zy
  if Zy and Zy.File and Zy.File.write then
    Zy.File.write(out, body)
  else
    local f = io.open(out, "w")
    if not f then return nil, "write_fail" end
    f:write(body); f:close()
  end
  return out
end

--- 仅模板路径（旧 7.35）
function M.generateTemplate(need, opts)
  opts = opts or {}
  need = tostring(need or "")
  local bid = opts.bid or M.get("bid") or "com.example.app"
  local dw = tonumber(opts.design_w) or 1136
  local dh = tonumber(opts.design_h) or 640
  local kind = "loop_task"
  local lower = need:lower()
  if need:find("登录") or lower:find("login") then kind = "login"
  elseif need:find("找色") or lower:find("color") then kind = "find_color"
  elseif need:find("OCR") or need:find("识字") or need:find("找字") then kind = "ocr"
  elseif need:find("状态") or need:find("状态机") or lower:find("state") then kind = "state_machine"
  elseif need:find("点击") or lower:find("tap") or lower:find("click") then kind = "auto_click"
  elseif need:find("领取") or need:find("奖励") or need:find("每天") or lower:find("reward") then kind = "loop_task"
  end
  local body
  local tpl, tpath = read_template(kind)
  if not tpl then return false, "template_missing:" .. tostring(tpath) end
  body = tpl
    :gsub('bid = "com%.example%.app"', string.format('bid = %q', bid))
    :gsub("design_w = 1136", "design_w = " .. tostring(dw))
    :gsub("design_h = 640", "design_h = " .. tostring(dh))
  body = "-- 由 Zy.Script.generateTemplate\n-- 需求：" .. need .. "\n-- 模板：" .. kind .. "\n" .. body
  local out = write_out(body, opts, "tpl")
  if not out then return false, "write_fail" end
  M.set("last_generated", out)
  M.set("last_generate_kind", "template:" .. kind)
  return true, out, body
end

--- 根据任务描述生成完整自动化流程（打通 Zy.AI）
function M.generateFromTask(task, opts)
  M.assertPlatform()
  opts = opts or {}
  task = tostring(task or "")
  local Zy = _G.Zy
  assert(Zy.AI, "Zy.AI required")
  local bid = opts.bid or M.get("bid") or "com.example.app"
  local dw = tonumber(opts.design_w) or 1136
  local dh = tonumber(opts.design_h) or 640

  local analysis = Zy.AI.analyzeNeed(task, { bid = bid, design_w = dw, design_h = dh })
  local ctx = { bid = bid, phase = "unknown", vision = {} }
  if opts.collect then
    local okc, c = pcall(Zy.AI.collect, bid, opts)
    if okc and type(c) == "table" then ctx = c end
  end
  local plan = Zy.AI.plan(task, ctx, {
    design_w = dw, design_h = dh, analysis = analysis, bid = bid,
  })
  local src = Zy.AI.generate(plan, { max_loop = opts.max_loop or 5 })
  local vok, vrep = M.validate({ code = src, require_begin = false })
  if not vok then
    return false, "validate_fail", vrep
  end
  local path = Zy.AI.save(src, {
    goal = task, bid = bid, plan = plan,
    name = opts.name or ("task_" .. tostring(os.time()) .. ".lua"),
  })
  if opts.out and opts.out ~= path then
    write_out(src, { out = opts.out }, "task")
    path = opts.out
  end
  M.set("last_generated", path)
  M.set("last_generate_kind", "ai_task")
  M.set("last_plan_phase", plan.phase)
  if Zy.Knowledge then
    Zy.Knowledge.save({
      task = task, bid = bid, path = path, ok = true,
      flow = table.concat(analysis.flow or {}, " | "),
      rules = table.concat(plan.funcs or {}, ","),
      phase = plan.phase, event = "generateFromTask",
    })
  end
  log("Script.generateFromTask -> " .. tostring(path))
  return true, path, src, plan, analysis
end

--- 根据 Game 状态生成下一步动作脚本片段/完整脚本
function M.generateFromState(state, opts)
  M.assertPlatform()
  opts = opts or {}
  local Zy = _G.Zy
  assert(Zy.AI, "Zy.AI required")
  state = tostring(state or (Zy.Game and Zy.Game.phase and Zy.Game.phase()) or "unknown")
  local bid = opts.bid or M.get("bid") or "com.example.app"
  local dw = tonumber(opts.design_w) or M.get("design_w") or 1136
  local dh = tonumber(opts.design_h) or M.get("design_h") or 640
  local suggest = Zy.StateMachine.suggest(state)
  local ctx = { bid = bid, phase = state, vision = opts.vision or {} }
  local plan = Zy.AI.plan("from_state:" .. state, ctx, {
    design_w = dw, design_h = dh, bid = bid,
  })
  plan.suggest = suggest
  local src = Zy.AI.generate(plan, { max_loop = opts.max_loop or 2 })
  local path = Zy.AI.save(src, {
    goal = "state:" .. state, bid = bid, plan = plan,
    name = opts.name or ("state_" .. state:gsub("%W", "_") .. ".lua"),
  })
  M.set("last_generated", path)
  M.set("last_generate_kind", "ai_state:" .. state)
  return true, path, src, plan
end

--- 根据运行日志优化已有脚本
function M.optimizeScript(path_or_src, log_text, opts)
  M.assertPlatform()
  opts = opts or {}
  local Zy = _G.Zy
  assert(Zy.AI, "Zy.AI required")
  local src = path_or_src
  if type(path_or_src) == "string" and path_or_src:find("%.lua$") and not path_or_src:find("function ", 1, true) then
    local f = io.open(path_or_src, "r")
    src = f and f:read("*a") or ""
    if f then f:close() end
  end
  log_text = tostring(log_text or M._last_error or "")
  local bid = opts.bid or M.get("bid") or "com.example.app"
  local goal = opts.goal or M.get("goal") or "optimize"
  local plan = {
    goal = goal, bid = bid,
    design_w = opts.design_w or 1136, design_h = opts.design_h or 640,
    phase = opts.phase or "unknown",
    action = { kind = "tap_ratio", rx = 0.5, ry = 0.72, label = "opt" },
    funcs = {},
  }
  local reason = log_text
  if log_text:find("login") or log_text:find("登录") then reason = "stuck_login" end
  if log_text:find("timeout") or log_text:find("超时") then reason = "timeout" end
  local new_plan = select(1, Zy.AI.optimize(plan, {
    reason = reason, ctx = { bid = bid, phase = plan.phase }, iter = opts.iter or 1,
  }))
  local body = Zy.AI.generate(new_plan, { max_loop = opts.max_loop or 4 })
  -- 保留原注释头
  body = "-- optimized by Script.optimizeScript\n-- log=" .. log_text:sub(1, 120) .. "\n" .. body
  local vok = select(1, M.validate({ code = body, require_begin = false }))
  if not vok then return false, "validate_fail", body end
  local out = write_out(body, opts, "opt")
  if Zy.Knowledge then
    Zy.Knowledge.save({
      task = goal, bid = bid, path = out, ok = true,
      optimize = reason, fail_reason = log_text:sub(1, 200), event = "optimizeScript",
    })
  end
  M.set("last_generated", out)
  M.set("last_generate_kind", "optimize")
  return true, out, body, new_plan
end

--- 根据错误自动修复脚本
function M.repairScript(path_or_src, err, opts)
  M.assertPlatform()
  opts = opts or {}
  err = tostring(err or M._last_error or "unknown")
  opts.goal = opts.goal or "repair"
  local ok, out, body, plan = M.optimizeScript(path_or_src, "repair:" .. err, opts)
  if not ok then return ok, out, body end
  -- 强制写入 recover 提示注释
  body = "-- repaired: " .. err:sub(1, 160) .. "\n" .. tostring(body)
  local path = write_out(body, { out = opts.out or out }, "repair")
  local Zy = _G.Zy
  if Zy and Zy.Knowledge then
    Zy.Knowledge.recordFailure({
      task = opts.goal, bid = opts.bid, path = path,
      fail_reason = err, optimize = "repairScript", event = "repair",
    })
  end
  M.set("last_generated", path)
  M.set("last_generate_kind", "repair")
  return true, path, body, plan
end

--- 自然语言生成（默认走 AI；opts.mode=\"template\" 走旧模板）
function M.generate(need, opts)
  M.assertPlatform()
  opts = opts or {}
  need = tostring(need or "")
  if opts.mode == "template" then
    return M.generateTemplate(need, opts)
  end
  -- 默认：AI 管线生成（offline 可跳过 collect）
  if opts.pipeline then
    local Zy = _G.Zy
    local rep = Zy.AI.pipeline(need, {
      bid = opts.bid or M.get("bid") or "com.example.app",
      design_w = opts.design_w or 1136,
      design_h = opts.design_h or 640,
      offline = opts.offline ~= false and not opts.collect,
      skip_test = opts.skip_test,
      light_test = opts.light_test,
      max_loop = opts.max_loop,
      name = opts.name,
    })
    M.set("last_generated", rep.path)
    M.set("last_generate_kind", "ai_pipeline")
    return rep.ok, rep.path, rep
  end
  opts.collect = opts.collect or false
  return M.generateFromTask(need, opts)
end

--- 调试快照：当前函数/坐标/截图/错误
-- @param opts table|nil { snapshot=true, path= }
-- @return table
function M.debug(opts)
  opts = opts or {}
  local Zy = _G.Zy
  local info = {
    ok = true,
    time = os.date("%Y-%m-%d %H:%M:%S"),
    fn = M.get("last_act") or M.get("suggest") or "(idle)",
    phase = M.get("phase") or (Zy and Zy.Game and Zy.Game.phase and Zy.Game.phase()) or "",
    bid = M.get("bid") or (C and C.bid) or "",
    design_w = M.get("design_w"),
    design_h = M.get("design_h"),
    orient = M.get("orient") or (C and C.orient),
    last_ok = M.get("last_ok"),
    last_reason = M.get("last_reason"),
    last_error = M._last_error,
    loop_i = M.get("loop_i"),
    screenshot = "",
    logic_w = 0,
    logic_h = 0,
  }
  if Zy and Zy.Screen and Zy.Screen.size then
    local w, h = Zy.Screen.size()
    info.logic_w, info.logic_h = w, h
  end
  if opts.snapshot ~= false and Zy and Zy.Screen and Zy.Screen.snapshot then
    local tag = "script_debug_" .. tostring(os.time())
    local ok, path = pcall(Zy.Screen.snapshot, tag)
    if ok then info.screenshot = tostring(path or tag) end
  end
  -- 坐标摘要（设计原点映射）
  if Zy and Zy.Coordinate and Zy.Coordinate.point and info.design_w then
    local ok, lx, ly = pcall(Zy.Coordinate.point, info.design_w / 2, info.design_h / 2)
    if ok then
      info.center_logic_x, info.center_logic_y = lx, ly
    end
  end

  local path = opts.path
  if not path then
    local vd = (Zy and Zy.File and Zy.File.varDir and Zy.File.varDir())
      or _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
    path = vd .. "/.ziyan_script_debug.txt"
  end
  local lines = {
    "=== Zy.Script.debug ===",
    "time=" .. info.time,
    "fn=" .. tostring(info.fn),
    "phase=" .. tostring(info.phase),
    "bid=" .. tostring(info.bid),
    "design=" .. tostring(info.design_w) .. "x" .. tostring(info.design_h),
    "logic=" .. tostring(info.logic_w) .. "x" .. tostring(info.logic_h),
    "center_logic=" .. tostring(info.center_logic_x) .. "," .. tostring(info.center_logic_y),
    "last_ok=" .. tostring(info.last_ok),
    "last_reason=" .. tostring(info.last_reason),
    "last_error=" .. tostring(info.last_error),
    "screenshot=" .. tostring(info.screenshot),
    "error_pos=last_act/phase (see fn/phase above)",
  }
  local f = io.open(path, "w")
  if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
  info.path = path
  if Zy and Zy.UI and Zy.UI.Dialog and opts.dialog then
    pcall(Zy.UI.Dialog.show, table.concat(lines, "\n"))
  elseif Zy and Zy.Log and Zy.Log.write then
    Zy.Log.write("Script.debug fn=" .. tostring(info.fn))
  end
  M.set("last_debug_path", path)
  return info
end

local REQUIRED_FUNCS = {
  "Device.refresh", "Screen.sync", "Coordinate.setDesign",
  "Touch.tapRatio", "Touch.tapDesign", "Image.findColor", "OCR.find",
  "Verify.act", "Game.phase", "Script.begin",
}

--- 校验模块/函数/参数依赖
-- @param opts table|nil { code=string, require_begin=true }
-- @return boolean, table  ok, report
function M.validate(opts)
  opts = opts or {}
  local Zy = _G.Zy
  local report = { ok = true, missing = {}, warnings = {}, checks = {} }
  if type(Zy) ~= "table" then
    report.ok = false
    report.missing[#report.missing + 1] = "Zy"
    return false, report
  end
  for _, fq in ipairs(REQUIRED_FUNCS) do
    local mod, fn = fq:match("^([%w]+)%.([%w]+)$")
    local ok = type(Zy[mod]) == "table" and type(Zy[mod][fn]) == "function"
    report.checks[fq] = ok
    if not ok then
      report.ok = false
      report.missing[#report.missing + 1] = fq
    end
  end
  -- 管道模块存在性
  for _, m in ipairs({
    "Device", "Screen", "Coordinate", "Vision", "Image", "OCR",
    "Touch", "Verify", "StateMachine", "Game", "Script", "AI",
    "Config", "Input",
  }) do
    if type(Zy[m]) ~= "table" then
      report.warnings[#report.warnings + 1] = "module_missing:" .. m
    end
  end
  if opts.require_begin ~= false then
    if not M.get("design_w") then
      report.warnings[#report.warnings + 1] = "no_Script.begin_yet"
    end
  end
  local code = opts.code
  if type(code) == "string" and #code > 0 then
    if code:find("Touch%.tap%s*%(") and not code:find("tapRatio") and not code:find("tapDesign") then
      report.ok = false
      report.warnings[#report.warnings + 1] = "forbidden_Touch.tap_physical"
    end
    if code:find("Touch%.click") then
      report.ok = false
      report.warnings[#report.warnings + 1] = "forbidden_Touch.click"
    end
  end
  M.set("last_validate_ok", report.ok)
  log("Script.validate ok=" .. tostring(report.ok)
    .. " missing=" .. tostring(#report.missing))
  return report.ok, report
end

--- SDK 根路径（模板所在）
function M.sdkRoot()
  return sdk_root()
end

return M
