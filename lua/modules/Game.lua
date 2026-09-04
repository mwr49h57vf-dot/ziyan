--[[ Zy.Game — 通用交互状态引擎（非游戏专用）
  状态：boot → loading → login → menu → role → running → error
  任何 App 测试均经本引擎分类；禁止按游戏名写死流程。
]]
local C = require("modules._ctx")
local M = { name = "Game", version = "2.0.0", model = "InteractionStateEngine" }

local function defined(n) return type(_G[n]) == "function" end

-- 通用词表（多语言/多 App 共用，非某游戏专属）
M.LEXICON = {
  loading = { "加载", "Loading", "请稍候", "正在进入", "%" },
  login = { "登录", "登陆", "账号", "密码", "注册", "Login", "Sign in", "Password", "免密" },
  menu = { "开始", "菜单", "设置", "公告", "活动", "Start", "Menu", "Settings" },
  role = { "选角", "角色", "创建角色", "选择角色", "进入游戏", "开始游戏" },
  error = { "错误", "失败", "网络异常", "重试", "Error", "Failed", "Retry" },
}

M.STATES = { "boot", "loading", "login", "menu", "role", "running", "error", "unknown" }

local function text_has(hay, words)
  hay = tostring(hay or "")
  if hay == "" then return false end
  for _, w in ipairs(words or {}) do
    if hay:find(tostring(w), 1, true) then return true, w end
  end
  return false
end

--- 通用界面分类：OCR 词表优先，辅以亮金按钮启发式（不绑定 Bundle）
function M.classify(bid, opts)
  bid = bid or C.bid
  opts = opts or {}
  local Zy = _G.Zy
  local App = Zy and Zy.App
  if App then
    local ws = App.windowState(bid)
    if ws.state == "stopped" or ws.springboard or (ws.front ~= "" and ws.front ~= bid) then
      return "boot", { via = "app_window", front = ws.front }
    end
  elseif defined("frontAppBid") and bid then
    local fr = tostring(frontAppBid() or "")
    if fr ~= "" and fr ~= tostring(bid) then
      return "boot", { via = "front", front = fr }
    end
  end

  local skip_ocr = opts.skip_ocr or opts.light or _G.__ZIYAN_OCR_NO_SHOT
  -- 找图优先于 OCR：机上 sidecar 会挂死，模板在盘时直接分类。
  if Zy and Zy.Image and type(Zy.Image.find) == "function" then
    local root = "/private/var/mobile/Media/ZiYan/templates"
    for _, st in ipairs({ "error", "loading", "login", "role", "menu" }) do
      for _, w in ipairs(M.LEXICON[st] or {}) do
        local file = tostring(w):gsub("[^%w%._%-]+", "_") .. ".png"
        local path = root .. "/" .. st .. "/" .. file
        local f = io.open(path, "rb")
        if f then
          f:close()
          local x, y = Zy.Image.find(path, tonumber(opts.fuzzy) or 80)
          x, y = tonumber(x), tonumber(y)
          if x and y and x >= 0 and y >= 0 then
            return st, { via = "image", word = w, x = x, y = y }
          end
        end
      end
    end
  end

  -- OCR/Vision 词表探测（通用词，不绑 Bundle）；无截图冒烟/探索模式跳过重 OCR
  if not skip_ocr then
    if defined("visionAnalyze") then
      for _, st in ipairs({ "error", "loading", "login", "role", "menu" }) do
        local hit, kind, x, y, c, detail = visionAnalyze({
          words = M.LEXICON[st],
          design_w = opts.design_w or C.design_w,
          design_h = opts.design_h or C.design_h,
        })
        if hit then
          return st, { via = "vision", kind = kind, word = detail and detail.word, x = x, y = y }
        end
      end
    elseif Zy and Zy.OCR and C.design_w then
      local ocr_text = Zy.OCR.region(0, 0, C.design_w, C.design_h)
      ocr_text = (type(ocr_text) == "string" and ocr_text) or ""
      for _, st in ipairs({ "error", "loading", "login", "role", "menu" }) do
        local hit, w = text_has(ocr_text, M.LEXICON[st])
        if hit then
          return st, { via = "ocr", word = w, text_len = #ocr_text }
        end
      end
    end
  end

  -- 亮色主按钮启发式 → 偏 login（不写死某游戏坐标）
  -- 冒烟无截图模式跳过扫金，避免高分屏 getColor 阻塞闭环
  if not _G.__ZIYAN_OCR_NO_SHOT and not opts.light and defined("gameFindBrightGold") then
    local Screen = Zy and Zy.Screen
    local w, h = 1136, 640
    if Screen then w, h = Screen.size() end
    local gx, gy, gc = gameFindBrightGold(w * 0.35, h * 0.45, w * 0.90, h * 0.92)
    if gx and gx ~= -1 then
      return "login", { via = "bright_control", x = gx, y = gy, c = gc }
    end
  end

  if App and App.isForeground(bid) then
    return "running", { via = "foreground_default" }
  end
  return "unknown", { via = "none" }
end

--- 当前状态（通用）
function M.phase(bid)
  local st = M.classify(bid)
  return st
end

function M.analyze(bid, opts)
  bid = bid or C.bid
  opts = opts or {}
  local st, detail = M.classify(bid, opts)
  local Zy = _G.Zy
  local shot = nil
  -- 冒烟/轻量：跳过落盘截图，避免真机 snapshot 阻塞闭环
  if not opts.light and not _G.__ZIYAN_OCR_NO_SHOT and Zy and Zy.Screen then
    shot = Zy.Screen.snapshot("analyze_" .. tostring(st))
  end
  local info = {
    bid = tostring(bid or ""),
    phase = st,
    state = st,
    detail = detail or {},
    shot = shot,
    front = Zy and Zy.App and Zy.App.front() or "",
    ts = os.time(),
  }
  return info
end

--- 建议动作（通用策略标签，非某游戏流程）
function M.suggest(state)
  state = tostring(state or "unknown")
  local map = {
    boot = "launch_app_and_sync",
    loading = "wait_and_reclassify",
    login = "pause_auth_skip_credentials",
    menu = "select_primary_entry_then_verify",
    role = "confirm_identity_then_verify",
    running = "observe_or_task_step",
    error = "capture_and_recover",
    unknown = "sync_vision_reclassify",
  }
  return map[state] or "sync_vision_reclassify"
end

--- 启动/关闭委托 App 抽象层（保留旧名兼容）
function M.open(bid, orient)
  bid = bid or C.bid
  C.set_bid(bid)
  C.orient = tonumber(orient) or C.orient or 1
  local Zy = _G.Zy
  if Zy and Zy.App then return Zy.App.launch(bid) end
  if defined("gameOpen") then return gameOpen(bid, C.orient) end
  return false
end

function M.close(bid)
  local Zy = _G.Zy
  if Zy and Zy.App then return Zy.App.close(bid or C.bid) end
  if defined("gameClose") then return gameClose(bid or C.bid) end
  return false
end

--- 已废弃：专用进角。保留桩以免旧脚本崩，统一走通用步进
function M.enterRole(bid, max_steps)
  return M.stepTo(bid, "running", max_steps or 6)
end

--- 通用步进：向目标状态推进（有限步 + 验证 + 禁同动作连点）
function M.stepTo(bid, target, max_steps)
  bid = bid or C.bid
  target = tostring(target or "running")
  max_steps = tonumber(max_steps) or 6
  local Zy = _G.Zy
  local last_label, stuck = "", 0
  for i = 1, max_steps do
    local fr = M.analyze(bid)
    if fr.phase == target then
      return true, fr
    end
    local label = M.suggest(fr.phase)
    if label == last_label then
      stuck = stuck + 1
      if stuck >= 2 then
        if Zy and Zy.Diagnose then Zy.Diagnose.onStuck(fr, label) end
        break
      end
    else
      stuck = 0
    end
    last_label = label
    if fr.phase == "boot" then
      M.open(bid, C.orient)
      if defined("mSleep") then mSleep(2000) end
      if Zy and Zy.Screen then Zy.Screen.sync(C.orient, bid) end
    elseif fr.phase == "loading" then
      if defined("mSleep") then mSleep(1500) end
    elseif fr.phase == "login" then
      -- P3 门禁不含填写账号密码：登录页安全暂停，不点登录钮、不填框。
      if Zy and Zy.Script then
        Zy.Script.set("paused_auth", true)
        Zy.Script.set("last_reason", "login_credentials_not_a_p3_gate")
      end
      return false, fr
    else
      -- 通用：点设计中心偏下一次（主 CTA 常见区），必须经 Verify
      if Zy and Zy.Script then
        local ok = Zy.Script.act(label, function(ctx)
          ctx.tapRatio(0.50, 0.72)
        end, 1200)
        if not ok and Zy.Diagnose then Zy.Diagnose.onStuck(fr, label) end
      end
    end
  end
  local fin = M.analyze(bid)
  return fin.phase == target, fin
end

function M.stateSuggest(st)
  return M.suggest(st)
end

return M
