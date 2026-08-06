--[[ 模板 01：基础自动化
  流程：初始化设备→设备信息→屏幕同步→识别状态→操作→验证→日志→异常恢复
  禁止固定坐标；仅用设计/比例坐标。
]]
_G.__ZIYAN_OCR_NO_SHOT = true

function main()
  if type(Zy) ~= "table" then require("modules") end

  -- 由调用方或环境注入；示例用设计分辨率占位
  local bid = Zy.Script.get("bid") or _G.__ZY_SCRIPT_BID
  local dw = tonumber(Zy.Script.get("design_w") or _G.__ZY_DESIGN_W)
  local dh = tonumber(Zy.Script.get("design_h") or _G.__ZY_DESIGN_H)
  assert(bid and dw and dh, "set bid/design_w/design_h before run")

  Zy.Script.begin({ bid = bid, design_w = dw, design_h = dh, orient = 1 })

  local p = Zy.Device.profile()
  Zy.Log(string.format("device %s %sx%s dpi=%s",
    tostring(p.model), tostring(p.logic_w), tostring(p.logic_h), tostring(p.dpi)))

  Zy.App.launch(bid, 2500)
  Zy.Screen.sync(1, bid)

  local fr = Zy.Game.analyze(bid)
  Zy.Script.set("phase", fr.phase)
  Zy.Log("phase=" .. tostring(fr.phase) .. " suggest=" .. Zy.Game.suggest(fr.phase))

  -- 安全比例点击 + 验证（非业务坐标写死）
  local ok, after, reason = Zy.Script.act("basic_safe_tap", function(ctx)
    ctx.tapRatio(0.08, 0.10)
  end, 800)

  Zy.File.write(Zy.File.varDir() .. "/.ziyan_script_basic.txt",
    string.format("ok=%s phase=%s reason=%s\n", tostring(ok), tostring(after and after.phase), tostring(reason)))

  if not ok then
    Zy.Script.recover({ phase = fr.phase, reason = reason, frame = after or fr, policy = "resync" })
  end

  Zy.Log(ok and "basic OK" or "basic VERIFY_FAIL")
end

return main
