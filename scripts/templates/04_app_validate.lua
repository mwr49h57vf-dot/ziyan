--[[ 模板 04：应用能力验证（游戏仅为测试 Bundle）
  使用 Zy.Engine.validate + 任务流；不写死游戏流程。
]]
_G.__ZIYAN_OCR_NO_SHOT = true

function main()
  if type(Zy) ~= "table" then require("modules") end
  local bid = Zy.Script.get("bid") or _G.__ZY_SCRIPT_BID
  local dw = tonumber(Zy.Script.get("design_w") or _G.__ZY_DESIGN_W)
  local dh = tonumber(Zy.Script.get("design_h") or _G.__ZY_DESIGN_H)
  assert(bid and dw and dh, "set bid/design_w/design_h")

  Zy.Script.clearVars()
  Zy.Script.set("bid", bid)
  Zy.Script.set("design_w", dw)
  Zy.Script.set("design_h", dh)
  Zy.Script.set("recover_policy", "resync")

  Zy.Script.defineTask("register", function()
    Zy.Case.registerApp({ bid = bid, action = "script_template_04", phase = "boot" })
    return true
  end)

  Zy.Script.defineTask("validate", function()
    local report = Zy.Engine.validate({
      bid = bid, design_w = dw, design_h = dh, orient = 1, wait_ms = 2000,
    })
    Zy.Script.set("validate_ok", report.ok)
    Zy.Script.set("validate_steps", #(report.steps or {}))
    return report.ok, report
  end)

  Zy.Script.defineTask("summary", function()
    local ok = Zy.Script.get("validate_ok")
    local line = string.format("app_validate bid=%s ok=%s steps=%s\n",
      bid, tostring(ok), tostring(Zy.Script.get("validate_steps")))
    Zy.File.write(Zy.File.varDir() .. "/.ziyan_script_app.txt", line)
    Zy.Log(line)
    return ok
  end)

  local results = Zy.Script.runTasks({ "register", "validate", "summary" })
  local all_ok = true
  for _, r in ipairs(results) do
    if not r.ok then all_ok = false end
  end
  if not all_ok then
    Zy.Script.recover({ reason = "task_pipeline_fail", policy = "resync" })
  end
end

return main
