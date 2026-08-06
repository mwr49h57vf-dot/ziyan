--[[ 模板：循环任务 ]]
function main()
  require("modules.init")
  Script.begin({
    bid = "com.example.app",
    design_w = 1136, design_h = 640, orient = 1,
  })
  App.launch(Script.get("bid"), 2000)

  Script.defineTask("claim", function()
    return Script.act("claim", function(ctx)
      local x, y = ctx.findText("领取")
      if x ~= -1 then ctx.tapHit(x, y) else ctx.tapRatio(0.5, 0.7) end
    end, 800)
  end)

  Script.loop(10, function(i, ctx)
    Log.write("loop i=" .. i .. " phase=" .. tostring(ctx.phase()))
    Script.runTask("claim")
    if ctx.phase() == "done" then return false end
    return true
  end)

  Log.write("loop_task template done")
end

main()
