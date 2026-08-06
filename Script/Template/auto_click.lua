--[[ 模板：自动点击（比例 / 设计坐标）
  用法：复制到 Media/ZiYan/scripts/ 后改 bid 与坐标。
]]
function main()
  require("modules.init")
  local Zy = Zy
  Script.begin({
    bid = "com.example.app",
    design_w = 1136, design_h = 640, orient = 1,
  })
  App.launch(Script.get("bid"), 2000)

  -- 推荐：比例点击（跨分辨率）
  Script.act("click_start", function(ctx)
    ctx.tapRatio(0.50, 0.78)
  end, 600)

  -- 或：设计坐标（须已 setDesign；Helper.tap = tapDesign）
  -- Helper 可选：dofile 仓库 Script/Helper/sdk.lua 后 Helper.install()
  Script.act("click_design", function(ctx)
    ctx.tapDesign(500, 300)
  end, 600)

  Log.write("auto_click template done")
end

main()
