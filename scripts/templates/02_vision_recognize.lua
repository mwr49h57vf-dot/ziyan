--[[ 模板 02：视觉识别
  Vision / Image / OCR → 命中则 tapHit → Verify
]]
_G.__ZIYAN_OCR_NO_SHOT = true

function main()
  if type(Zy) ~= "table" then require("modules") end
  local bid = Zy.Script.get("bid") or _G.__ZY_SCRIPT_BID
  local dw = tonumber(Zy.Script.get("design_w") or _G.__ZY_DESIGN_W)
  local dh = tonumber(Zy.Script.get("design_h") or _G.__ZY_DESIGN_H)
  assert(bid and dw and dh, "set bid/design_w/design_h")

  Zy.Script.begin({ bid = bid, design_w = dw, design_h = dh, orient = 1 })
  Zy.App.launch(bid, 2000)
  Zy.Screen.sync(1, bid)

  local words = Zy.Script.get("words") or { "登录", "开始", "确定", "进入" }
  local hit, kind, x, y, c, detail = Zy.Vision.analyze({
    words = words,
    design_w = dw, design_h = dh,
  })

  Zy.Script.set("vision_hit", hit)
  Zy.Log(string.format("vision hit=%s kind=%s xy=%s,%s",
    tostring(hit), tostring(kind), tostring(x), tostring(y)))

  if hit and x and x ~= -1 then
    local ok, after, reason = Zy.Script.act("vision_tap_hit", function(ctx)
      ctx.tapHit(x, y)
    end, 1000)
    Zy.File.write(Zy.File.varDir() .. "/.ziyan_script_vision.txt",
      string.format("hit=true ok=%s reason=%s word=%s\n",
        tostring(ok), tostring(reason), tostring(detail and detail.word)))
    if not ok then
      Zy.Script.recover({ reason = reason, frame = after, policy = "resync" })
    end
  else
    -- 找色兜底（设计区域中央偏下）
    local fx, fy = Zy.Image.findColor(0xE8C070, "", 70, dw * 0.3, dh * 0.5, dw * 0.9, dh * 0.95)
    Zy.Log(string.format("color fallback %s,%s", tostring(fx), tostring(fy)))
    Zy.File.write(Zy.File.varDir() .. "/.ziyan_script_vision.txt",
      string.format("hit=false color=%s,%s\n", tostring(fx), tostring(fy)))
  end
end

return main
