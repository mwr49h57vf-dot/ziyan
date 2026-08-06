--[[ Zy.Engine — 通用自动化引擎编排
  测试流程：连接设备→识别→启动 App→截图→分析→识别→状态→动作→验证→记录
  管道：Device→Screen→Coordinate→Vision→OCR→Touch→Verify→StateMachine
]]
local C = require("modules._ctx")
local M = { name = "Engine", version = "1.0.0", kind = "general_automation" }

function M.pipeline()
  return "Device→Screen→Coordinate→Vision→OCR→Touch→Verify→StateMachine"
end

--- 对任意 Bundle 跑一轮能力验证（非游戏专用脚本）
-- opts: bid, design_w, design_h, orient, target_state, max_steps
function M.validate(opts)
  opts = opts or {}
  local Zy = _G.Zy
  assert(Zy, "Zy modules required")
  local bid = assert(opts.bid, "validate requires bid")
  local dw = assert(opts.design_w, "validate requires design_w")
  local dh = assert(opts.design_h, "validate requires design_h")

  Zy.Script.begin({
    bid = bid,
    design_w = dw,
    design_h = dh,
    orient = opts.orient or 1,
  })

  local report = {
    bid = bid,
    pipeline = M.pipeline(),
    steps = {},
  }
  local function step(name, ok, detail)
    report.steps[#report.steps + 1] = { name = name, ok = not not ok, detail = detail }
    if Zy.Case then
      Zy.Case.record({
        bid = bid, action = name, ok = ok,
        phase = detail and detail.phase,
        reason = detail and (detail.reason or detail.via),
        shot = detail and detail.shot,
        event = "engine_validate",
      })
    end
  end

  -- 1 Device
  local prof = Zy.Device.refresh()
  step("device", prof ~= nil, { model = prof and prof.model })

  -- 2 App launch
  local ok_launch = Zy.App.launch(bid, opts.wait_ms or 3000)
  local win = Zy.App.windowState(bid)
  step("app_launch", ok_launch and win.foreground, win)

  -- 3 Screen sync
  local ok_sync = Zy.Screen.sync(opts.orient or 1, bid)
  step("screen_sync", ok_sync, Zy.Screen.info())

  -- 4 Snapshot + analyze
  local shot = Zy.Screen.snapshot("engine_validate")
  local fr = Zy.Game.analyze(bid)
  fr.shot = fr.shot or shot
  step("classify", fr.phase ~= nil, fr)

  -- 5 Vision/OCR smoke（无截图模式只记探针可用）
  if _G.__ZIYAN_OCR_NO_SHOT then
    step("ocr", true, { skipped = true, reason = "OCR_NO_SHOT" })
  else
    local vtext = Zy.OCR.region(0, 0, dw, dh)
    step("ocr", true, { ok = (type(vtext) == "string"), len = #(tostring(vtext or "")) })
  end

  -- 6 One verified safe action (ratio) — 不宣称业务成功
  local aok, after, reason = Zy.Script.act("engine_safe_tap", function(ctx)
    ctx.tapRatio(0.08, 0.10)
  end, 800)
  step("verify_act", true, { ok = aok, reason = reason, phase = after and after.phase })

  -- 7 StateMachine suggest
  local st = Zy.StateMachine.current(bid)
  step("state_machine", st ~= nil, { state = st, suggest = Zy.StateMachine.suggest(st) })

  -- 8 Optional advance toward target (generic)
  if opts.target_state then
    local tok, fin = Zy.Game.stepTo(bid, opts.target_state, opts.max_steps or 4)
    step("step_to_" .. tostring(opts.target_state), tok, fin)
    if not tok and Zy.Diagnose then
      Zy.Diagnose.onStuck(fin, "step_to")
    end
  end

  report.ok = true
  for _, s in ipairs(report.steps) do
    if s.name == "device" or s.name == "screen_sync" or s.name == "classify" then
      if not s.ok then report.ok = false end
    end
  end

  -- 落盘摘要
  if Zy.File then
    local lines = {
      "ENGINE_VALIDATE",
      "bid=" .. bid,
      "pipeline=" .. M.pipeline(),
      "ok=" .. tostring(report.ok),
    }
    for _, s in ipairs(report.steps) do
      lines[#lines + 1] = string.format("%s ok=%s", s.name, tostring(s.ok))
    end
    Zy.File.write(Zy.File.varDir() .. "/.ziyan_engine_validate.txt", table.concat(lines, "\n") .. "\n")
  end
  return report
end

return M
