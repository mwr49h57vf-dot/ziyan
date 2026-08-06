--[[ 模板：找色点击 ]]
function main()
  require("modules.init")
  Script.begin({
    bid = "com.example.app",
    design_w = 1136, design_h = 640, orient = 1,
  })
  App.launch(Script.get("bid"), 2000)
  Screen.keep(true)

  Script.act("findcolor_tap", function(ctx)
    local x, y = ctx.findColor(0xE8C070, "", 90, 400, 300, 1100, 620)
    if x ~= -1 then
      ctx.tapHit(x, y)
    else
      ctx.tapRatio(0.64, 0.72) -- 兜底
    end
  end, 800)

  Screen.keep(false)
  Log.write("find_color template done")
end

main()
