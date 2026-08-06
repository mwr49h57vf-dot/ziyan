--[[ 模板：OCR 找字点击 ]]
function main()
  require("modules.init")
  Script.begin({
    bid = "com.example.app",
    design_w = 1136, design_h = 640, orient = 1,
  })
  App.launch(Script.get("bid"), 2000)

  Script.act("ocr_tap", function(ctx)
    local x, y = ctx.findText("领取", 0, 0, 1136, 640)
    if x ~= -1 then
      ctx.tapHit(x, y)
    else
      Log.write("未找到「领取」")
    end
  end, 1000)

  local text = OCR.region(50, 50, 1000, 200)
  Log.write("ocr_sample=" .. tostring(text)) -- text 或 nil
end

main()
