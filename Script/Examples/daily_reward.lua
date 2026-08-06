--[[ 示例：每天自动领取奖励（由 Script.generate 同类意图生成）]]
function main()
  require("modules.init")
  Script.begin({
    bid = Script.get("bid") or "com.example.app",
    design_w = 1136, design_h = 640, orient = 1,
  })
  App.launch(Script.get("bid"), 2500)

  Script.loop(5, function(i, ctx)
    local st = ctx.phase()
    Log.write("day_reward i=" .. i .. " phase=" .. tostring(st))
    if st == "dialog" or st == "login" then
      Script.act("dismiss_or_login", function(c)
        local x, y = c.findText("领取")
        if x == -1 then x, y = c.findText("确定") end
        if x ~= -1 then c.tapHit(x, y) else c.tapRatio(0.5, 0.65) end
      end, 900)
    else
      Script.act("claim_reward", function(c)
        local x, y = c.findText("领取")
        if x ~= -1 then c.tapHit(x, y) else c.tapRatio(0.72, 0.18) end
      end, 900)
    end
    return true
  end)

  Script.debug({ snapshot = true })
  Log.write("daily_reward example done")
end

main()
