--[[ 模板：状态机驱动 ]]
function main()
  require("modules.init")
  Script.begin({
    bid = "com.example.app",
    design_w = 1136, design_h = 640, orient = 1,
  })
  App.launch(Script.get("bid"), 2000)

  local handlers = {
    login = function(ctx)
      ctx.tapRatio(0.64, 0.72)
    end,
    dialog = function(ctx)
      local x, y = ctx.findText("确定")
      if x ~= -1 then ctx.tapHit(x, y) else ctx.tapRatio(0.5, 0.6) end
    end,
    running = function(ctx)
      Log.write("already running")
    end,
    default = function(ctx, fr)
      Log.write("default phase=" .. tostring(fr and fr.phase))
      ctx.tapRatio(0.5, 0.5)
    end,
  }

  for _ = 1, 8 do
    local ok, fr, reason = Script.tick({ handlers = handlers, wait_ms = 800 })
    Log.write(string.format("tick ok=%s phase=%s reason=%s",
      tostring(ok), tostring(fr and fr.phase), tostring(reason)))
    if fr and fr.phase == "running" then break end
  end
end

main()
