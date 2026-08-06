--[[ 模板 03：状态机驱动
  识别状态 → StateMachine.suggest → handlers → Verify；支持循环与 untilPhase
]]
_G.__ZIYAN_OCR_NO_SHOT = true

function main()
  if type(Zy) ~= "table" then require("modules") end
  local bid = Zy.Script.get("bid") or _G.__ZY_SCRIPT_BID
  local dw = tonumber(Zy.Script.get("design_w") or _G.__ZY_DESIGN_W)
  local dh = tonumber(Zy.Script.get("design_h") or _G.__ZY_DESIGN_H)
  assert(bid and dw and dh, "set bid/design_w/design_h")

  Zy.Script.begin({ bid = bid, design_w = dw, design_h = dh, orient = 1 })
  Zy.App.launch(bid, 2500)

  local handlers = {
    boot = function(ctx)
      Zy.App.launch(bid, 2000)
      Zy.Screen.sync(1, bid)
    end,
    loading = function(ctx) end,
    login = function(ctx)
      ctx.tapRatio(0.64, 0.72)
    end,
    menu = function(ctx)
      ctx.tapRatio(0.50, 0.70)
    end,
    role = function(ctx)
      ctx.tapRatio(0.50, 0.75)
    end,
    running = function(ctx)
      Zy.Script.set("reached_running", true)
    end,
    error = function(ctx)
      Zy.Script.recover({ policy = "relaunch", reason = "state_error" })
    end,
    default = function(ctx, fr)
      ctx.tapRatio(0.50, 0.60)
    end,
  }

  Zy.Script.loop(4, function(i, ctx)
    local ok, fr, reason = Zy.Script.tick({ handlers = handlers, wait_ms = 1000 })
    Zy.Log(string.format("loop %d ok=%s phase=%s reason=%s",
      i, tostring(ok), tostring(fr and fr.phase), tostring(reason)))
    if Zy.Script.get("reached_running") then return false end
    if fr and fr.phase == "running" then return false end
    return true
  end)

  local reached, st = Zy.Script.untilPhase("running", 3000, 500)
  Zy.File.write(Zy.File.varDir() .. "/.ziyan_script_sm.txt",
    string.format("reached=%s phase=%s loops=%s\n",
      tostring(reached), tostring(st), tostring(Zy.Script.get("loop_done"))))
  Zy.Log("state_machine template done phase=" .. tostring(Zy.Game.phase(bid)))
end

return main
