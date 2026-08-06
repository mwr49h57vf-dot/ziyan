--[[ 模板：登录（比例点输入框 + Input）
  注意：账号密码请用 Config / Script.set，勿硬编码进仓库提交。
]]
function main()
  require("modules.init")
  Script.begin({
    bid = "com.example.app",
    design_w = 1136, design_h = 640, orient = 1,
  })
  local user = Config.get("login", "user", "") or Script.get("user", "")
  local pass = Config.get("login", "pass", "") or Script.get("pass", "")
  App.launch(Script.get("bid"), 2500)

  Script.act("focus_user", function(ctx)
    ctx.tapRatio(0.50, 0.40)
  end, 400)
  Input.text(tostring(user))

  Script.act("focus_pass", function(ctx)
    ctx.tapRatio(0.50, 0.48)
  end, 400)
  Input.text(tostring(pass))

  Script.act("login_btn", function(ctx)
    local x, y = ctx.findText("登录")
    if x ~= -1 then ctx.tapHit(x, y) else ctx.tapRatio(0.64, 0.72) end
  end, 1200)

  Log.write("login template done phase=" .. tostring(Game.phase()))
end

main()
