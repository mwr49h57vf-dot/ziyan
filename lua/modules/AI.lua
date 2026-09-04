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

local function var_dir()
  local Zy = _G.Zy
  if Zy and Zy.File and type(Zy.File.varDir) == "function" then
    local ok, path = pcall(Zy.File.varDir)
    if ok and type(path) == "string" and path ~= "" then return path end
  end
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function read_kv_file(path)
  local Zy = _G.Zy
  local raw = ""
  if Zy and Zy.File and type(Zy.File.read) == "function" then
    raw = Zy.File.read(path) or ""
  end
  local out = {}
  for line in tostring(raw):gmatch("[^\r\n]+") do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then out[key] = value end
  end
  return out, raw
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
  local gameplay = opts.gameplay == true
  Zy.Device.refresh()
  local prof = Zy.Device.profile() or {}
  if bid then
    Zy.App.launch(bid, opts.wait_ms or 2000)
    Zy.Screen.sync(opts.orient or C.orient or 1, bid)
  end
  local si = Zy.Screen.info() or {}
  -- P3 gameplay explores through current-frame classification only. Device OCR
  -- sidecars have stalled on target games, while templates remain usable.
  local fr = Zy.Game.analyze(bid, gameplay and { skip_ocr = true, light = true } or nil)
  local st = Zy.StateMachine.current(bid)
  local suggest = Zy.StateMachine.suggest(st)
  local shot = nil
  if not gameplay and not _G.__ZIYAN_OCR_NO_SHOT then
    shot = Zy.Screen.snapshot("ai_collect")
  end

  local vision = { hit = false }
  if not gameplay and not _G.__ZIYAN_OCR_NO_SHOT then
    local hit, kind, x, y, c, detail = Zy.Vision.analyze({
      words = opts.words or { "开始", "确定", "进入", "继续" },
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
  -- P3 门禁不含填写账号密码：识别到登录只记 skip_auth，绝不把「登录」当可点词。
  if need:find("登录") or lower:find("login") then
    tasks[#tasks + 1] = "skip_auth"
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
  local capability
  if need:find("世界") or need:find("玩法") or need:find("自研") or
      need:find("探索") or lower:find("gameplay") then
    capability = "gameplay"
  elseif need:find("聊天") or lower:find("chat") then
    capability = "chat"
  elseif need:find("游戏规则") or need:find("规则引擎") or lower:find("rule engine") then
    capability = "rules"
  elseif need:find("自动决策") or need:find("决策") or lower:find("decision") then
    capability = "decision"
  elseif need:find("非视觉") or need:find("剪贴板") or need:find("硬件键") or lower:find("non.visual") then
    capability = "non_visual"
  end
  if #tasks == 0 then tasks[1] = "advance_ui" end
  local modules = {
    "Device", "Screen", "Coordinate", "Vision", "Image", "OCR",
    "Touch", "Verify", "StateMachine", "Game", "Script",
  }
  if capability == "gameplay" then
    modules[#modules + 1] = "Decision"
    modules[#modules + 1] = "RuleEngine"
    modules[#modules + 1] = "Chat"
    modules[#modules + 1] = "Knowledge"
  end
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
    capability = capability,
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
    local vword = tostring((ctx.vision.detail and ctx.vision.detail.word) or ctx.vision.kind or "")
    if vword:find("登录") or vword:find("账号") or vword:find("密码") or vword:lower():find("login") or vword:lower():find("password") then
      action = { kind = "pause_auth", label = "p3_skip_credentials" }
      table.insert(steps, { kind = "pause_auth", desc = "auth word is not a P3 gate" })
    else
      action = {
        kind = "tap_ratio",
        rx = math.max(0.05, math.min(0.95, ctx.vision.rx)),
        ry = math.max(0.05, math.min(0.95, ctx.vision.ry)),
        label = "ai_vision_ratio",
      }
      table.insert(steps, { kind = "vision", desc = "Vision hit → tapRatio" })
    end
  else
    if phase == "login" or (analysis.tasks[1] == "login") or (analysis.tasks[1] == "skip_auth") then
      action = { kind = "pause_auth", label = "p3_skip_credentials" }
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
    capability = analysis.capability,
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

  if plan.capability == "gameplay" then
    L("-- AI-GENERATED GAMEPLAY by Zy.AI " .. M.version)
    L("-- real-device P3: observe -> decide -> rule -> world greeting -> knowledge")
    L("-- RULES: Zy.* only; no fixed physical coords; no auth credentials")
    L("")
    L("local function ailog(msg) print(tostring(msg)) end")
    L("")
    L("function main()")
    L("  if type(Zy) ~= \"table\" then require(\"modules\") end")
    L(string.format("  local BID = %q", bid))
    L(string.format("  local DW, DH = %d, %d", dw, dh))
    L("  local Game, Decision, Rules = Zy.Game, Zy.Decision, Zy.RuleEngine")
    L("  local Chat, Knowledge = Zy.Chat, Zy.Knowledge")
    L("  if type(Game) ~= \"table\" or type(Decision) ~= \"table\" or type(Rules) ~= \"table\" or type(Chat) ~= \"table\" or type(Knowledge) ~= \"table\" then")
    L("    return false, \"gameplay_module_missing\"")
    L("  end")
    L("  Zy.Device.refresh()")
    L("  Zy.Script.begin({ bid = BID, design_w = DW, design_h = DH, orient = 1 })")
    L("  Zy.Coordinate.setDesign(DW, DH)")
    L("  Zy.App.launch(BID, 800)")
    L("  Zy.Screen.sync(1, BID)")
    L("  local frame = Game.analyze(BID, { skip_ocr = true, light = true, fuzzy = 80 })")
    L("  local phase = tostring(frame.phase or \"unknown\")")
    L("  Zy.Script.set(\"gameplay_phase\", phase)")
    L("  ailog(\"GAMEPLAY phase=\" .. phase)")
    L("  if phase == \"login\" then")
    L("    Zy.Script.set(\"paused_auth\", true)")
    L("    Zy.Script.set(\"done\", true)")
    L("    Zy.File.write(Zy.File.varDir() .. \"/.ziyan_agent_gameplay_result\", \"status=PAUSED_SAFE\\nphase=login\\nreason=login_credentials_not_a_p3_gate\\n\")")
    L("    return false, \"login_credentials_not_a_p3_gate\"")
    L("  end")
    L("  if phase == \"role\" then")
    L("    local role_path = \"/private/var/mobile/Media/ZiYan/templates/role/进入游戏.png\"")
    L("    local x, y = Zy.Image.find(role_path, 80)")
    L("    x, y = tonumber(x), tonumber(y)")
    L("    if x and y and x >= 0 and y >= 0 then")
    L("      local entered = Zy.Touch.tapHit(x, y)")
    L("      Zy.File.write(Zy.File.varDir() .. \"/.ziyan_agent_gameplay_result\", \"status=ROLE_ENTRY_ATTEMPT\\nphase=role\\naction=visible_enter_game\\nok=\" .. tostring(entered ~= false) .. \"\\n\")")
    L("      return entered ~= false, entered and \"visible_enter_game\" or \"enter_game_tap_failed\"")
    L("    end")
    L("    return false, \"visible_enter_game_not_found\"")
    L("  end")
    L("  if phase ~= \"running\" then")
    L("    Zy.File.write(Zy.File.varDir() .. \"/.ziyan_agent_gameplay_result\", \"status=INCONCLUSIVE\\nphase=\" .. phase .. \"\\nreason=not_playable\\n\")")
    L("    return false, \"not_playable:\" .. phase")
    L("  end")
    L("  local decision = Decision.new({ id = \"gameplay_world_hello\" })")
    L("  local rules = Rules.new({ id = \"gameplay_world_hello\", initial_state = \"running\" })")
    L("  Rules.add(rules, { id = \"world_channel\", when = function(ctx) return ctx.phase == \"running\" end, [\"then\"] = function(_, engine) engine.state = \"world_ready\"; engine.score = engine.score + 1 end })")
    L("  local rule_ok, rule_event = Rules.step(rules, { phase = phase })")
    L("  local turn_ok, turn_reason = false, \"rule_not_ready\"")
    L("  Decision.add(decision, { id = \"world_hello\", when = function(ctx) return ctx.rule_ok and ctx.rule_state == \"world_ready\" end, run = function()")
    L("    turn_ok, turn_reason = Chat.playTurn(\"你好\", {")
    L("      channel_labels = { \"世界\" }, focus_ratio = { x = 0.36, y = 0.91 }, skip_ocr = true,")
    L("      dismiss_ratio = { x = 0.361, y = 0.342 }, send_labels = { \"发送\" },")
    L("      echo_phase = \"chat_echo\", fuzzy = 80, close_ratio = { x = 0.62, y = 0.12 },")
    L("      verify = true,")
    L("    })")
    L("    return turn_ok")
    L("  end })")
    L("  local chosen, choice_event = Decision.choose(decision, { rule_ok = rule_ok, rule_state = rules.state })")
    L("  local ok = rule_ok and chosen and turn_ok")
    L("  local snap = Rules.snapshot(rules)")
    L("  Knowledge.save({ task = \"AI 自研游戏玩法\", bid = BID, ok = ok, phase = phase,")
    L("    rules = \"world_channel\", flow = \"Game.analyze>Decision>RuleEngine>Chat.playTurn>Knowledge\",")
    L("    fail_reason = ok and \"\" or tostring(turn_reason), event = \"gameplay_world_hello\" })")
    L("  Zy.Script.set(\"capability_gameplay\", ok)")
    L("  Zy.Script.set(\"capability_detail\", \"phase=\" .. phase .. \";rule=\" .. tostring(rule_ok) .. \";decision=\" .. tostring(chosen) .. \";chat=\" .. tostring(turn_ok) .. \";reason=\" .. tostring(turn_reason))")
    L("  local go = Zy.File.read(Zy.File.varDir() .. \"/.ziyan_capability_context\") or Zy.File.read(Zy.File.varDir() .. \"/.ziyan_embed_go\") or \"\"")
    L("  local nonce = go:match(\"nonce=([^\\r\\n]+)\") or \"\"")
    L("  local session_id = go:match(\"session_id=([^\\r\\n]+)\") or \"\"")
    L("  local prof = Zy.Device.profile() or {}")
    L("  local front = Zy.App.front()")
    L("  local detail = Zy.Script.get(\"capability_detail\") or \"\"")
    L("  local function kv(v) return tostring(v or \"\"):gsub(\"[\\r\\n]\", \" \") end")
    L("  Zy.File.write(Zy.File.varDir() .. \"/.ziyan_capability_result\",")
    L("    \"result_ready=1\\ncapability=gameplay\\nmodule_ok=\" .. tostring(ok) .. \"\\nreal_device=true\\nnonce=\" .. kv(nonce) .. \"\\nsession_id=\" .. kv(session_id) .. \"\\nfront=\" .. kv(front) .. \"\\ndevice_model=\" .. kv(prof.model) .. \"\\ndetail=\" .. kv(detail) .. \"\\nreason=\" .. kv(turn_reason) .. \"\\n\")")
    L("  Zy.File.write(Zy.File.varDir() .. \"/.ziyan_agent_gameplay_result\",")
    L("    \"status=\" .. (ok and \"BUSINESS_PASS\" or \"INCONCLUSIVE\") .. \"\\nphase=\" .. phase .. \"\\nrule_state=\" .. tostring(snap.state) .. \"\\nchat_verified=\" .. tostring(turn_ok) .. \"\\nreason=\" .. tostring(turn_reason) .. \"\\n\")")
    L("  if ok then Zy.Script.set(\"done\", true) end")
    L("  return ok, choice_event")
    L("end")
    L("")
    L("return main")
    L("")
    local gameplay_src = table.concat(lines, "\n")
    local login_find = "ctx.findText(" .. string.char(34) .. "登录" .. string.char(34) .. ")"
    for _, forbidden in ipairs({
      "openFixture", "Input.text", "点击前往", "ziyan-device-chat", login_find,
    }) do
      if gameplay_src:find(forbidden, 1, true) then
        error("AI.generate gameplay refused: " .. forbidden)
      end
    end
    return gameplay_src
  end

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
  if plan.capability then
    L("")
    L("  -- Capability suite is generated by Zy.AI and executes only Zy modules.")
    L("  Zy.Script.defineTask(\"capability_suite\", function()")
    if plan.capability == "chat" then
      L("    local Chat = Zy.Chat")
      L("    if type(Chat) ~= \"table\" then return false, \"chat_module_missing\" end")
      L("    local ok_fixture, fixture_reason = Chat.openFixture({ title = \"聊天测试\" })")
      L("    if not ok_fixture then return false, fixture_reason or \"chat_fixture_failed\" end")
      L("    local ok_begin = Chat.begin({ id = \"device_chat_suite\" })")
      L("    local ok_clear = Chat.clear()")
      L("    local labels = { \"输入消息\", \"输入\", \"消息\", \"Message\" }")
      L("    local send_labels = { \"发送\", \"Send\" }")
      L("    local ok_turn1 = Chat.send(\"ziyan-device-chat-1\", { focus_labels = labels, send_labels = send_labels })")
      L("    local ok_copy = Chat.copyLast({ action_labels = { \"复制\" } })")
      L("    local ok_paste = Chat.pasteLast({ action_labels = { \"粘贴\" } })")
      L("    local ok_turn2 = Chat.send(\"ziyan-device-chat-2\", { focus_labels = labels, send_labels = send_labels })")
      L("    local ok_result, result_reason = Chat.verifyLast({ text = \"ziyan-device-chat-2\" })")
      L("    local st = Chat.state()")
      L("    local ok = ok_begin and ok_clear and ok_turn1 and ok_copy and ok_paste and ok_turn2 and ok_result and st.count >= 2")
      L("    Zy.Script.set(\"capability_chat\", ok)")
      L("    Chat.endSession()")
      L("    Zy.Script.set(\"capability_detail\", \"input=1;send=1;multi_turn=1;copy=\" .. tostring(ok_copy) .. \";paste=\" .. tostring(ok_paste) .. \";result=\" .. tostring(ok_result) .. \";reason=\" .. tostring(result_reason))")
      L("    return ok, ok and \"chat_business_device_verified\" or \"chat_business_failed\"")
    elseif plan.capability == "rules" then
      L("    local R = Zy.RuleEngine")
      L("    if type(R) ~= \"table\" then return false, \"rule_module_missing\" end")
      L("    local e = R.new({ id = \"device_rules_suite\", initial_state = \"ready\" })")
      L("    R.add(e, { id = \"advance\", when = function(ctx, x) return ctx.advance == true and x.state == \"ready\" end, [\"then\"] = function(_, x) x.state = \"running\"; x.score = x.score + 1 end })")
      L("    local ok_step = R.step(e, { advance = true })")
      L("    local ok_repeat, repeat_reason = R.step(e, { advance = true })")
      L("    local ok_pause = R.pause(e, \"device_pause\") and R.step(e, { advance = true }) == false")
      L("    local ok_resume = R.resume(e) and R.step(e, { advance = true }) == false")
      L("    local snap = R.snapshot(e)")
      L("    local replay = R.replay(e, { { advance = false } })")
      L("    local ok_timeout = Zy.Script.untilPhase(\"__ziyan_never__\", 1, 1) == false")
      L("    local ok = ok_step and not ok_repeat and repeat_reason == \"no_rule\" and ok_pause and ok_resume and ok_timeout and snap.state == \"running\" and snap.score == 1 and snap.turn >= 2 and #replay == 1")
      L("    Zy.Script.set(\"capability_rules\", ok)")
      L("    Zy.Script.set(\"capability_detail\", \"normal=1;error=\" .. tostring(not ok_repeat) .. \";repeat=\" .. tostring(not ok_repeat) .. \";pause_resume=1;timeout=\" .. tostring(ok_timeout) .. \";trace=\" .. tostring(#snap.trace))")
      L("    return ok, ok and \"rules_business_device_verified\" or \"rules_business_failed\"")
    elseif plan.capability == "decision" then
      L("    local D = Zy.Decision")
      L("    if type(D) ~= \"table\" then return false, \"decision_module_missing\" end")
      L("    local e = D.new({ id = \"device_decision_suite\" }); local ran = false")
      L("    D.add(e, { id = \"choose_a\", when = function(ctx) return ctx.pick == \"a\" end, run = function() ran = true; return true end })")
      L("    local ok_choose = D.choose(e, { pick = \"a\" }); local ok_retry = D.retry(e, \"choose_a\", 2)")
      L("    local ok_retry_limit = D.retry(e, \"choose_a\", 2) and D.retry(e, \"choose_a\", 2) == false")
      L("    local ok_pause = D.pause(e, \"device_pause\") and D.choose(e, { pick = \"a\" }) == false")
      L("    local ok_resume = D.resume(e) and D.choose(e, { pick = \"a\" }) == true")
      L("    local snap = D.snapshot(e)")
      L("    local replay = D.replay(e, { { pick = \"a\" }, { pick = \"missing\" } })")
      L("    local ok = ok_choose and ok_retry and ok_retry_limit and ok_pause and ok_resume and ran and snap.cursor >= 2 and #snap.trace >= 2 and #replay == 2")
      L("    Zy.Script.set(\"capability_decision\", ok)")
      L("    Zy.Script.set(\"capability_detail\", \"choose=1;retry=1;retry_limit=\" .. tostring(ok_retry_limit) .. \";pause_resume=1;replay=\" .. tostring(#replay == 2) .. \";trace=\" .. tostring(#snap.trace))")
      L("    return ok, ok and \"decision_business_device_verified\" or \"decision_business_failed\"")
    else
      L("    local C = Zy.Clipboard; local I = Zy.Input; local T = Zy.Touch; local A = Zy.App; local D = Zy.Device")
      L("    if type(C) ~= \"table\" or type(I) ~= \"table\" or type(T) ~= \"table\" or type(A) ~= \"table\" or type(D) ~= \"table\" then return false, \"non_visual_module_missing\" end")
      L("    local token = \"ziyan-device-clipboard\"")
      L("    local wrote = C.set(token); local got = C.get(); local pasted = C.pasteToFocus(); local cleared = C.clear()")
      L("    local swiped = T.swipeRatio(0.20, 0.80, 0.80, 0.80, 3, 5)")
      L("    local long = T.longPressRatio(0.50, 0.50, 20)")
      L("    local multi = T.pinch(DW / 2, DH / 2, 20, 10, 2, 5)")
      L("    local lock = D.lock(); local unlock = D.unlock()")
      L("    local home = I.pressHome(40)")
      L("    local lifecycle = A.launch(BID, 500); local state = A.windowState(BID); A.close(BID); A.activate(BID, 500)")
      L("    local ok = wrote and got == token and pasted ~= false and cleared ~= false and swiped ~= false and long ~= false and multi ~= false and lock ~= false and unlock ~= false and home ~= false and lifecycle ~= false and state.bid == BID")
      L("    Zy.Script.set(\"capability_non_visual\", ok)")
      L("    Zy.Script.set(\"capability_detail\", \"input=1;clipboard=1;gesture=1;multi_touch=\" .. tostring(multi ~= false) .. \";lock_unlock=\" .. tostring(lock ~= false and unlock ~= false) .. \";home=\" .. tostring(home ~= false) .. \";app_lifecycle=\" .. tostring(lifecycle ~= false))")
      L("    return ok, ok and \"non_visual_business_device_verified\" or \"non_visual_business_failed\"")
    end
    L("  end)")
    L("  local cap_ok, cap_reason = Zy.Script.runTask(\"capability_suite\")")
    L("  ailog(\"CAPABILITY_SUITE ok=\" .. tostring(cap_ok) .. \" reason=\" .. tostring(cap_reason))")
    L("  local function capability_kv()")
    L("    local var = Zy.File.varDir()")
    L("    local go = Zy.File.read(var .. \"/.ziyan_capability_context\") or Zy.File.read(var .. \"/.ziyan_embed_go\") or \"\"")
    L("    local nonce = go:match(\"nonce=([^\\r\\n]+)\") or \"\"")
    L("    local session_id = go:match(\"session_id=([^\\r\\n]+)\") or \"\"")
    L("    local prof = Zy.Device.profile() or {}")
    L("    local front = Zy.App.front()")
    L("    local detail = Zy.Script.get(\"capability_detail\") or \"\"")
    L("    local function kv_value(value) return (tostring(value or \"\"):gsub(\"[\\r\\n]\", \" \")) end")
    L("    return table.concat({")
    L("      \"result_ready=1\",")
    L("      " .. string.format("%q", "capability=" .. tostring(plan.capability)) .. ",")
    L("      \"module_ok=\" .. tostring(cap_ok),")
    L("      \"real_device=true\",")
    L("      \"nonce=\" .. kv_value(nonce),")
    L("      \"session_id=\" .. kv_value(session_id),")
    L("      \"front=\" .. kv_value(front),")
    L("      \"device_model=\" .. kv_value(prof.model),")
    L("      \"detail=\" .. kv_value(detail),")
    L("      \"reason=\" .. kv_value(cap_reason),")
    L("    }, string.char(10)) .. string.char(10)")
    L("  end")
    L("  Zy.File.write(Zy.File.varDir() .. \"/.ziyan_capability_result\", capability_kv())")
  end
  L("")
  L("  local handlers = {")
  L("    boot = function(ctx) Zy.App.launch(BID, 600); Zy.Screen.sync(1, BID) end,")
  L("    loading = function(ctx) end,")
  L("    login = function(ctx)")
  L("      -- P3：登录页不是门禁。禁止点登录、禁止 Input.text 填账号密码。")
  L("      Zy.Script.set(\"paused_auth\", true)")
  L("      Zy.Script.set(\"done\", true)")
  L("      ailog(\"PAUSED_SAFE reason=login_credentials_not_a_p3_gate\")")
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
  L("      if x ~= -1 then ctx.tapHit(x, y) else")
  L(string.format("        ctx.tapRatio(%.4f, %.4f)", rx, ry))
  L("      end")
  L("    end,")
  L("  }")
  L("")
  L("  -- 视觉增强：Vision/OCR/Image；冒烟可设 __ZIYAN_OCR_NO_SHOT")
  local words = plan.words or { "开始", "确定", "进入", "领取" }
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
  if opts.real_device ~= true then
    local detail = {
      path = path_or_src,
      phase = "not_run",
      reason = "REAL_DEVICE_TEST_REQUIRED",
      real_device = false,
      functional_pass = false,
    }
    M.record({
      goal = opts.goal, bid = opts.bid, path = path_or_src, ok = false,
      reason = detail.reason, event = "test_blocked_local", iter = opts.iter,
    })
    return false, detail
  end
  local path = path_or_src
  if type(path_or_src) == "string" and path_or_src:find("function main", 1, true) then
    path = M.save(path_or_src, { goal = opts.goal or "inline", bid = opts.bid, name = "ai_inline_test.lua" })
  end
  log("AI.test " .. tostring(path))
  local source = ""
  do
    local f = io.open(path, "r")
    if f then source = f:read("*a") or ""; f:close() end
  end
  if not source:find("AI%-GENERATED", 1, false) or not source:find("Zy%.", 1, false) then
    local detail = {
      path = path,
      phase = "not_run",
      reason = "GENERATED_ZY_MODULE_SOURCE_REQUIRED",
      real_device = true,
      functional_pass = false,
    }
    M.record({
      goal = opts.goal, bid = opts.bid, path = path, ok = false,
      reason = detail.reason, event = "test_source_rejected", iter = opts.iter,
    })
    return false, detail
  end
  -- 本地 load-only/light-test 只能是语法检查，绝不计入功能通过。
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
      goal = opts.goal, bid = opts.bid, path = path, ok = false,
      reason = ok and "LOCAL_LOAD_ONLY_NOT_FUNCTIONAL_PASS" or tostring(e),
      event = "test_load", iter = opts.iter,
    })
    return false, {
      path = path, phase = "load_only", err = e, load_only = true,
      real_device = false, functional_pass = false,
    }
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
  local evidence, evidence_raw = {}, ""
  if opts.require_capability_evidence then
    evidence, evidence_raw = read_kv_file(var_dir() .. "/.ziyan_capability_result")
  end
  local evidence_ready = evidence.result_ready == "1"
  local capability_evidence = (not opts.require_capability_evidence) or (
    evidence_ready and evidence.real_device == "true"
      and evidence.module_ok == "true"
      and evidence.capability ~= nil
      and evidence.session_id ~= nil and evidence.session_id ~= ""
      and evidence.nonce ~= nil and evidence.nonce ~= ""
      and evidence.front ~= nil and evidence.front ~= ""
  )
  local gen_ok = ok_run == true
  local reason = gen_ok and ("ran phase=" .. tostring(phase)) or tostring(err)
  if opts.require_capability_evidence and not capability_evidence then
    gen_ok = false
    reason = "CAPABILITY_EVIDENCE_INCOMPLETE"
  end
  pcall(M.record, {
    goal = opts.goal, bid = opts.bid, path = path, ok = gen_ok,
    reason = reason, phase = phase, event = "test", iter = opts.iter,
  })
  return gen_ok, {
    path = path, phase = phase, err = err,
    business_done = not not Zy.Script.get("done"),
    real_device = true, functional_pass = gen_ok,
    RESULT_READY = evidence_ready,
    capability_evidence = capability_evidence,
    session_id = evidence.session_id,
    nonce = evidence.nonce,
    cleanup_active = false,
    evidence = evidence_raw,
  }
end

--- 根据失败原因调整计划
function M.optimize(plan, fail_info)
  fail_info = fail_info or {}
  plan = plan or {}
  local reason = tostring(fail_info.reason or "")
  local tune = { shift_x = 0, shift_y = 0 }
  if reason:find("still_login", 1, true) then
    plan.action = { kind = "pause_auth", label = "p3_skip_credentials" }
  elseif reason:find("no_change", 1, true) then
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
    local ok, detail = M.test(path, {
      goal = goal, bid = bid, iter = iter,
      real_device = opts.real_device == true,
      light_test = false,
    })
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
  local gameplay = opts.gameplay == true or analysis.capability == "gameplay"
  if gameplay then
    analysis.capability = "gameplay"
    opts.gameplay = true
    opts.skip_ocr = true
  end
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

  -- 7 本地只做语法加载检查，不作为功能测试或 PASS。
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
  stage("本地语法检查", ok_sim, tostring(err_sim))

  -- 8 真机测试：必须显式 real_device=true；跳过或本地调用均失败闭环。
  local tok, detail = false, {}
  if opts.skip_test or opts.real_device ~= true then
    stage("真机测试", false, "REAL_DEVICE_TEST_REQUIRED")
    tok = false
    detail = {
      phase = "not_run", path = path,
      reason = "REAL_DEVICE_TEST_REQUIRED",
      real_device = false, functional_pass = false,
    }
  else
    -- 真机路径执行完整视觉/触控链，不设置 OCR_NO_SHOT 或 light_test。
    local prev = _G.__ZIYAN_OCR_NO_SHOT
    _G.__ZIYAN_OCR_NO_SHOT = false
    tok, detail = M.test(path, {
      goal = goal, bid = bid, iter = 1,
      real_device = true,
      light_test = false,
      load_only = opts.load_only,
      require_capability_evidence = plan.capability ~= nil,
    })
    _G.__ZIYAN_OCR_NO_SHOT = prev
    detail = detail or {}
    stage("真机测试", tok, detail.reason or detail.phase or detail.err)
  end

  -- 9 结果验证
  local verified = tok and detail.real_device == true and detail.functional_pass == true
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

  report.ok = verified
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
