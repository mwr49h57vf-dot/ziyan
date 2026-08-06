--[[ 子砚 Game 模块
  游戏状态 / 学习表 / 自动生成脚本 / 异常恢复
  习惯来源：TS 薄入口+厚任务、配置驱动坐标、生命周期保活 —— 全部自实现
]]
local M = { module = "game", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function media_dir()
  if type(_G.ZIYAN_SCRIPTS) == "string" and #_G.ZIYAN_SCRIPTS > 0 then
    return _G.ZIYAN_SCRIPTS
  end
  return "/private/var/mobile/Media/ZiYan"
end

local function is_rootless()
  return io.open("/var/jb/usr/lib/ziyan/var", "r") ~= nil
end

--- 默认测游 Bundle：USB 拔刀 / LAN 仙侠类
function M.defaultBid()
  return is_rootless() and "com.ljzbbadao.game" or "com.xztl.ios"
end

local learned = {}

local function learn_path()
  return var_dir() .. "/.ziyan_learned_steps.json"
end

local function codegen_path()
  return media_dir() .. "/_zy_auto_gen_game.lua"
end

local function log_path()
  return var_dir() .. "/.ziyan_game_play_log.txt"
end

local function heart_path()
  return var_dir() .. "/.ziyan_game_play_alive"
end

function M.beat()
  pcall(function()
    local f = io.open(heart_path(), "w")
    if f then f:write(tostring(os.time()) .. "\n"); f:close() end
  end)
end

function M.log(msg)
  M.beat()
  pcall(function()
    local f = io.open(log_path(), "a")
    if f then
      f:write(os.date("%H:%M:%S ") .. tostring(msg) .. "\n")
      f:close()
    end
  end)
end

function M.loadLearned()
  learned = {}
  local f = io.open(learn_path(), "r")
  if not f then return learned end
  local body = f:read("*a") or ""
  f:close()
  for line in body:gmatch("[^\r\n]+") do
    local lab, x, y, via = line:match("^([^|]+)|(%-?%d+)|(%-?%d+)|([^|]*)")
    if lab and x then
      learned[#learned + 1] = {
        label = lab, x = tonumber(x), y = tonumber(y), via = via or "",
      }
    end
  end
  return learned
end

function M.saveLearned(bid)
  bid = bid or M.defaultBid()
  pcall(function()
    local f = io.open(learn_path(), "w")
    if not f then return end
    for _, s in ipairs(learned) do
      f:write(string.format("%s|%d|%d|%s\n", s.label, s.x, s.y, s.via or ""))
    end
    f:close()
  end)
  M.codegen(bid)
end

function M.remember(label, x, y, via, bid)
  if not x or x < 0 then return false end
  for _, s in ipairs(learned) do
    if s.label == label and math.abs(s.x - x) < 48 and math.abs(s.y - y) < 48 then
      return false
    end
  end
  learned[#learned + 1] = { label = label, x = x, y = y, via = via or "" }
  if #learned > 40 then table.remove(learned, 1) end
  M.saveLearned(bid)
  M.log(string.format("LEARN +%s @%d,%d via=%s total=%d", label, x, y, tostring(via), #learned))
  return true
end

function M.getLearned()
  return learned
end

--- 用已学步骤生成可运行自动化脚本（含状态判断/恢复/色参，非录制）
function M.codegen(bid)
  bid = bid or M.defaultBid()
  local n_color = 0
  pcall(function()
    local f = io.open(codegen_path(), "w")
    if not f then return end
    f:write("--[[ 自动生成：Game.codegen — Screen/OCR/Touch/Game + COLOR_PARAM ]]\n")
    f:write(string.format("-- bid=%s generated=%s steps=%d\n", bid, os.date("%Y-%m-%d %H:%M:%S"), #learned))
    f:write("_G.__ZIYAN_OCR_NO_SHOT = true\n")
    f:write("init(1)\n")
    f:write("keepScreen(true)\n")
    f:write(string.format('local BID = "%s"\n', bid))
    -- 写入最近色参对照，供状态判断
    local color_lines = {}
    for _, s in ipairs(learned) do
      if (s.label or ""):find("色参:", 1, true) then
        local hex = (s.via or ""):match("0x(%x+)") or "0"
        color_lines[#color_lines + 1] = string.format(
          "  {x=%d,y=%d,c=0x%s,tag=%q},", s.x, s.y, hex, s.label)
      end
    end
    n_color = #color_lines
    f:write("local COLOR_PARAMS = {\n")
    for _, line in ipairs(color_lines) do f:write(line .. "\n") end
    f:write("}\n")
    f:write([[
local function still_login()
  if type(gameDetectState) == "function" then
    return gameDetectState(BID) == "login"
  end
  for _, p in ipairs(COLOR_PARAMS) do
    local c = getColor(p.x, p.y) or 0
    local r = math.floor(c / 0x10000) % 256
    local g = math.floor(c / 0x100) % 256
    local b = c % 256
    if r > 70 and g > 40 and b < 160 and r >= g - 8 then return true end
  end
  return false
end
local function color_retry_tap()
  for _, p in ipairs(COLOR_PARAMS) do
    if (p.tag or ""):find("btn", 1, true) then
      toast("色参重试", 600)
      tap(p.x, p.y)
      mSleep(1800)
      return true
    end
  end
  return false
end
if type(gameHygiene) == "function" then gameHygiene() end
-- 标准启动链：runApp → mSleep(3000) → syncGameScreen
if type(gameOpen) == "function" then
  gameOpen(BID, 1)
else
  runApp(BID)
  mSleep(3000)
  if type(syncGameScreen) == "function" then syncGameScreen(1, BID) end
end
if type(gameSync) == "function" then gameSync(1, BID) end
toast("自动脚本启动", 1200)
mSleep(1500)
]])
    for i, s in ipairs(learned) do
      local phase = "task"
      local lab = s.label or ""
      if lab:find("色参:", 1, true) then
        -- 色参只写入表，不单独空点
        f:write(string.format("-- [color] keep %s @%d,%d via=%s\n", lab, s.x, s.y, s.via or ""))
      else
        if lab:find("登录", 1, true) or lab:find("免密", 1, true) or lab:find("仙侠", 1, true) then
          phase = "login"
        elseif lab:find("进角", 1, true) or lab:find("热区", 1, true) then
          phase = "enter"
        elseif lab:find("隐私", 1, true) then
          phase = "privacy"
        end
        f:write(string.format(
          "-- [%s] step %d %s via=%s\nif type(gameRecover) == \"function\" then gameRecover(BID, 1) end\nif type(gameSync) == \"function\" then gameSync(1, BID) end\ntoast(\"自动:%s\", 800)\ntap(%d, %d)\nmSleep(1600)\n",
          phase, i, lab, s.via or "", lab, s.x, s.y))
        if phase == "login" then
          f:write("if still_login() then toast(\"登录未过-色参重试\", 800); if not color_retry_tap() then tap(" .. s.x .. ", " .. s.y .. ") end; mSleep(2000) end\n")
        end
      end
    end
    f:write([[
-- 异常恢复收尾
if still_login() then color_retry_tap() end
if type(gameRecover) == "function" then gameRecover(BID, 1) end
if type(gameHygiene) == "function" then gameHygiene() end
if type(gameLog) == "function" then gameLog("auto_gen_done") end
toast("自动脚本结束", 1200)
]])
    f:write("-- 生成结束\n")
    f:close()
  end)
  M.log(string.format("CODEGEN steps=%d colors=%d path=%s", #learned, n_color, codegen_path()))
  return codegen_path()
end

--- 粗检界面状态：login / privacy / playing / unknown
-- 细粒度状态机见 gamePhase()
function M.detectState(bid)
  bid = bid or M.defaultBid()
  -- 必须前台是目标游戏，否则 SpringBoard/其它 App 会被误判 playing
  if defined("frontAppBid") then
    local fr = tostring(frontAppBid() or "")
    if fr ~= "" and fr ~= tostring(bid) then
      return "unknown"
    end
  end
  local w, h = M.screenSize()
  if defined("keepScreen") then pcall(keepScreen, false) end
  if not defined("getColor") then return "unknown" end

  local function near_white(c)
    c = tonumber(c) or 0
    local r = math.floor(c / 0x10000) % 256
    local g = math.floor(c / 0x100) % 256
    local b = c % 256
    return r > 210 and g > 210 and b > 210
  end

  -- 拔刀：先判登录钮，避免亮色 UI 被误判 privacy
  if bid == "com.ljzbbadao.game" then
    local gx, gy = math.floor(w * 1103 / 2208), math.floor(h * 796 / 1242)
    local c = getColor(gx, gy) or 0
    local r = math.floor(c / 0x10000) % 256
    local g = math.floor(c / 0x100) % 256
    local b = c % 256
    -- 登录金钮含亮金 0xCDA059（r 可 >200）
    if r > 70 and g > 40 and g < 200 and b < 160 and r >= g - 15 and (r - b) > 40 then
      return "login"
    end
    -- 隐私：白卡片 + 右上深色 X 区
    local white_hits = 0
    local samples = {
      { 0.45, 0.35 }, { 0.55, 0.35 }, { 0.50, 0.48 },
      { 0.42, 0.55 }, { 0.58, 0.55 },
    }
    for _, p in ipairs(samples) do
      if near_white(getColor(math.floor(w * p[1]), math.floor(h * p[2]))) then
        white_hits = white_hits + 1
      end
    end
    local xx, xy = math.floor(w * 1532 / 2208), math.floor(h * 269 / 1242)
    local xc = getColor(xx, xy) or 0
    local xr = math.floor(xc / 0x10000) % 256
    local xg = math.floor(xc / 0x100) % 256
    local xb = xc % 256
    local x_dark = (xr + xg + xb) < 280
    if white_hits >= 4 and x_dark then
      return "privacy"
    end
    return "playing"
  end

  if bid == "com.xztl.ios" then
    local gx, gy = math.floor(w * 729 / 1136), math.floor(h * 465 / 640)
    local c = getColor(gx, gy) or 0
    local r = math.floor(c / 0x10000) % 256
    local g = math.floor(c / 0x100) % 256
    local b = c % 256
    -- 近白：可能是键盘/输入遮罩，不算 playing
    if r > 230 and g > 230 and b > 230 then
      return "login"
    end
    -- 金/铜登录钮（含暗金 0x857146）；灰钮 0xD5D2D4 不算
    local gold = (r > 140 and g > 90 and b < 160 and r >= g - 10 and (r - b) > 40)
    local copper = (r > 100 and g > 70 and b < 120 and r >= g and (r - b) > 35 and r < 220)
    local dim_gold = (r > 110 and r < 160 and g > 80 and g < 140 and b < 100 and (r - b) > 30)
    if gold or copper or dim_gold then
      return "login"
    end
    local ax, ay = math.floor(w * 795 / 1136), math.floor(h * 204 / 640)
    local ac = getColor(ax, ay) or 0
    local ar = math.floor(ac / 0x10000) % 256
    local ag = math.floor(ac / 0x100) % 256
    local ab = ac % 256
    if ar < 90 and ag < 70 and ab < 60 and r > 90 and g > 60 and (r - b) > 25 then
      return "login"
    end
    return "playing"
  end
  return "unknown"
end

--- 状态机相位（目标：boot/login/server/role_select/entering/main/task/privacy）
-- detectState + 色指纹 + Vision 词表；禁止无验证连点
M.PHASES = {
  "boot", "login", "server", "role_select", "entering", "main", "task", "privacy", "unknown",
}

--- 在区域内找最亮金钮（逻辑坐标），失败返回 -1,-1,0
-- 自适应步长：限制采样上限，避免高分屏卡死
function M.findBrightGold(x1, y1, x2, y2)
  if not defined("getColor") then return -1, -1, 0 end
  x1, y1, x2, y2 = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2)
  if x2 < x1 then x1, x2 = x2, x1 end
  if y2 < y1 then y1, y2 = y2, y1 end
  local bw, bh = math.max(1, x2 - x1), math.max(1, y2 - y1)
  local step = 12
  local cells = math.ceil(bw / step) * math.ceil(bh / step)
  if cells > 220 then
    step = math.max(12, math.ceil(math.sqrt((bw * bh) / 220)))
  end
  local bestx, besty, best, bestc = -1, -1, -1, 0
  local locked = false
  if defined("keepScreen") then
    locked = pcall(keepScreen, true)
  end
  for y = y1, y2, step do
    for x = x1, x2, step do
      local c = tonumber(getColor(x, y)) or 0
      local r = math.floor(c / 0x10000) % 256
      local g = math.floor(c / 0x100) % 256
      local b = c % 256
      if r > 180 and g > 110 and b < 190 and (r - b) > 45 then
        local s = r * 2 + g - b
        if s > best then
          best, bestx, besty, bestc = s, x, y, c
        end
      end
    end
  end
  if locked and defined("keepScreen") then pcall(keepScreen, false) end
  return bestx, besty, bestc
end

--- 分析当前帧：同步 → 相位 + 关键点色（供知识库）
-- opts.light=true 时跳过扫金（验证相位用，防高分屏超时）
function M.analyzeFrame(bid, opts)
  bid = bid or M.defaultBid()
  opts = opts or {}
  if defined("syncScreen") then
    pcall(syncScreen, 1, bid)
  elseif defined("syncGameScreen") then
    pcall(syncGameScreen, 1, bid)
  end
  local w, h = M.screenSize()
  local st = M.detectState(bid)
  local ph = M.phase(bid)
  local cx = math.floor(w / 2)
  local cy = math.floor(h / 2)
  local center = defined("getColor") and (tonumber(getColor(cx, cy)) or 0) or 0
  local gx, gy, gc = -1, -1, 0
  if not opts.light then
    if bid == "com.xztl.ios" then
      gx, gy, gc = M.findBrightGold(w * 0.50, h * 0.55, w * 0.90, h * 0.90)
    elseif bid == "com.ljzbbadao.game" then
      gx, gy, gc = M.findBrightGold(w * 0.35, h * 0.55, w * 0.75, h * 0.85)
    end
  end
  local front = defined("frontAppBid") and tostring(frontAppBid() or "") or ""
  local info = {
    bid = bid, state = st, phase = ph, w = w, h = h, front = front,
    center = center, gold_x = gx, gold_y = gy, gold_c = gc,
  }
  if defined("learnRecord") and not opts.light then
    learnRecord({
      bid = bid, state = ph, action = "analyzeFrame",
      ok = true, x = gx, y = gy,
      detail = string.format("st=%s c=0x%06X g=0x%06X@%d,%d front=%s", st, center, gc, gx, gy, front),
    })
  end
  return info
end

function M.phase(bid)
  bid = bid or M.defaultBid()
  local st = M.detectState(bid)
  if st == "privacy" then return "privacy" end
  if st == "login" then return "login" end
  if st == "playing" then
    if defined("visionAnalyze") then
      local hit, kind, x, y, c, detail = visionAnalyze({
        words = { "选角", "创建角色", "选择角色", "开始游戏", "进入游戏" },
      })
      if hit then
        local ww = detail and detail.word or ""
        if tostring(ww):find("选", 1, true) or tostring(ww):find("角色", 1, true) then
          return "role_select"
        end
        if tostring(ww):find("进入", 1, true) or tostring(ww):find("开始", 1, true) then
          return "entering"
        end
      end
      local hit2 = visionAnalyze({ words = { "服务器", "区服", "选服" } })
      if hit2 then return "server" end
    end
    return "main"
  end
  if st == "unknown" then return "boot" end
  return "unknown"
end

--- 验证操作：login/privacy 必须相位离开；禁止钮变暗当成功
function M.verifyAdvance(bid, before_ph, label)
  before_ph = tostring(before_ph or "")
  if defined("mSleep") then mSleep(1200) end
  if defined("syncScreen") then
    pcall(syncScreen, 1, bid)
  elseif defined("syncGameScreen") then
    pcall(syncGameScreen, 1, bid)
  end
  local after = M.analyzeFrame(bid, { light = true })
  local ok = false
  if before_ph == "login" then
    ok = after.phase ~= "login" and after.phase ~= "privacy"
        and after.phase ~= "boot" and after.phase ~= "unknown"
  elseif before_ph == "privacy" then
    ok = after.phase ~= "privacy"
  else
    ok = after.phase ~= before_ph
  end
  M.log(string.format("verify %s before=%s after=%s ok=%s",
    tostring(label), before_ph, tostring(after.phase), tostring(ok)))
  if defined("learnRecord") then
    learnRecord({
      bid = bid, state = after.phase, action = "verify:" .. tostring(label),
      ok = ok, detail = before_ph .. "->" .. after.phase,
    })
  end
  if not ok then
    if defined("learnError") then
      learnError({
        type = "no_phase_change", module = "game",
        cause = tostring(label) .. " " .. before_ph .. "->" .. after.phase,
        fix = "auth path / credential; do not re-tap same button",
      })
    end
    if defined("verifyFailReport") then
      verifyFailReport({
        bid = bid, phase = after.phase, front = after.front,
        reason = tostring(label) .. ":" .. before_ph .. "->" .. after.phase,
        module = "game.verifyAdvance",
        fix = (before_ph == "login")
          and "password empty or auth reject; need real credential / working 免密"
          or "reclassify UI via screen_sync + state_machine",
        tag = tostring(label or "adv"),
      })
    end
  end
  return ok, after
end

--- 进入角色闭环：截图→分析→状态→单次动作→验证；禁登录连点
function M.enterRole(bid, max_steps)
  bid = bid or M.defaultBid()
  max_steps = tonumber(max_steps) or 6
  local last_label, last_ph = "", ""
  local login_tried = false
  for step = 1, max_steps do
    local fr = M.analyzeFrame(bid)
    M.log(string.format("enterRole step=%d phase=%s gold@%d,%d front=%s",
      step, tostring(fr.phase), fr.gold_x or -1, fr.gold_y or -1, tostring(fr.front)))
    if fr.phase == "main" or fr.phase == "task" then
      M.log("enterRole DONE phase=" .. fr.phase)
      return true, fr
    end
    if fr.phase == "role_select" or fr.phase == "entering" or fr.phase == "server" then
      local label = "adv_" .. fr.phase
      if label == last_label and fr.phase == last_ph then
        M.log("enterRole STOP same_button " .. label)
        if defined("verifyFailReport") then
          verifyFailReport({
            bid = bid, phase = fr.phase, front = fr.front,
            reason = "same_button:" .. label,
            module = "game.enterRole",
            fix = "stop repeat; OCR/坐标重标定后换动作",
            tag = "same_btn",
          })
        end
        break
      end
      last_label, last_ph = label, fr.phase
      local before = fr.phase
      local dw = (bid == "com.xztl.ios") and 1136 or 2208
      local dh = (bid == "com.xztl.ios") and 640 or 1242
      if defined("syncTap") then
        syncTap(math.floor(dw * 0.5), math.floor(dh * 0.72), dw, dh)
      elseif defined("coordTap") then
        coordTap(math.floor(dw * 0.5), math.floor(dh * 0.72), dw, dh)
      elseif defined("tap") then
        pcall(tap, math.floor(fr.w * 0.5), math.floor(fr.h * 0.72))
      end
      local ok = M.verifyAdvance(bid, before, label)
      if ok then
        local fr2 = M.analyzeFrame(bid)
        if fr2.phase == "main" or fr2.phase == "task" then return true, fr2 end
      end
    elseif fr.phase == "privacy" then
      if last_label == "privacy" and last_ph == "privacy" then
        M.log("enterRole STOP privacy_stuck")
        break
      end
      last_label, last_ph = "privacy", "privacy"
      M.dismissPrivacy(bid, fr.w, fr.h)
      M.verifyAdvance(bid, "privacy", "privacy")
    elseif fr.phase == "login" then
      if login_tried then
        M.log("enterRole STOP login_already_tried")
        if defined("verifyFailReport") then
          verifyFailReport({
            bid = bid, phase = "login", front = fr.front,
            reason = "login_stuck_after_one_verified_attempt",
            module = "game.enterRole",
            fix = "credential/免密通路；禁止再点同一登录钮",
            tag = "login_stuck",
          })
        end
        break
      end
      login_tried = true
      last_label, last_ph = "login", "login"
      local before = fr.phase
      -- 登录函数内部只做一次触控；结果以外层 verify 为准
      if bid == "com.xztl.ios" then
        if type(M.loginXztl) == "function" then M.loginXztl(bid, fr.w, fr.h) end
      else
        if type(M.loginBadao) == "function" then M.loginBadao(bid, fr.w, fr.h) end
      end
      local ok, after = M.verifyAdvance(bid, before, "login")
      if not ok then
        M.log("enterRole login verify FAIL phase=" .. tostring(after and after.phase))
        break
      end
    else
      M.log("enterRole unknown phase=" .. tostring(fr.phase))
      if defined("mSleep") then mSleep(800) end
    end
  end
  local fin = M.analyzeFrame(bid)
  local role_ok = (fin.phase == "main" or fin.phase == "task")
  if not role_ok and defined("verifyFailReport") then
    verifyFailReport({
      bid = bid, phase = fin.phase, front = fin.front,
      reason = "enterRole_end phase=" .. tostring(fin.phase),
      module = "game.enterRole",
      fix = "unblock login auth then resume state_machine",
      tag = "enter_role_end",
    })
  end
  return role_ok, fin
end

--- 关闭隐私协议：短按多点同意/X（避免长按出拷贝菜单）
function M.dismissPrivacy(bid, w, h)
  bid = bid or M.defaultBid()
  w = w or select(1, M.screenSize())
  h = h or select(2, M.screenSize())
  if defined("tap") then pcall(tap, math.floor(w * 0.12), math.floor(h * 0.50)) end
  if defined("mSleep") then mSleep(300) end
  local pts = {
    { math.floor(w * 1064 / 2208), math.floor(h * 921 / 1242), "隐私同意" },
    { math.floor(w * 1102 / 2208), math.floor(h * 891 / 1242), "隐私同意2" },
    { math.floor(w * 0.50), math.floor(h * 0.72), "隐私同意中" },
    { math.floor(w * 0.50), math.floor(h * 0.78), "隐私同意下" },
    { math.floor(w * 1532 / 2208), math.floor(h * 269 / 1242), "关隐私X" },
    { math.floor(w * 0.92), math.floor(h * 0.18), "关隐私X2" },
    { math.floor(w * 0.88), math.floor(h * 0.22), "关隐私X3" },
  }
  -- 找色：青绿同意条
  if defined("findMultiColorInRegionFuzzy") then
    local fx, fy = findMultiColorInRegionFuzzy(
      0x3CB371, "0|0|0x3CB371,10|0|0x2ECC71,0|6|0x27AE60", 70,
      math.floor(w * 0.25), math.floor(h * 0.55),
      math.floor(w * 0.75), math.floor(h * 0.92))
    if fx and fx ~= -1 then
      table.insert(pts, 1, { fx, fy, "隐私同意色" })
    end
  end
  for _, p in ipairs(pts) do
    if defined("tap") then pcall(tap, p[1], p[2]) end
    M.remember(p[3], p[1], p[2], "privacy_short", bid)
    if defined("mSleep") then mSleep(550) end
    if M.detectState(bid) ~= "privacy" then
      M.log("privacy_cleared via=" .. p[3])
      return true
    end
  end
  M.log("privacy_still")
  return false
end

function M.open(bid, orient)
  bid = bid or M.defaultBid()
  orient = tonumber(orient) or 1
  for _ = 1, 4 do
    M.beat()
    if defined("runApp") then runApp(bid) end
    if defined("waitFrontApp") then pcall(waitFrontApp, bid, 5000) else
      if defined("mSleep") then mSleep(1500) end
    end
    local fr = (defined("frontAppBid") and frontAppBid()) or ""
    if fr == bid or (defined("appRunning") and appRunning(bid)) then
      if defined("syncGameScreen") then syncGameScreen(orient, bid) end
      return true
    end
    if defined("mSleep") then mSleep(700) end
  end
  return false
end

function M.close(bid)
  bid = bid or M.defaultBid()
  if defined("closeApp") then closeApp(bid, 1) end
  if defined("softSync") then softSync() end
  if defined("mSleep") then mSleep(1200) end
end

function M.sync(orient, bid)
  bid = bid or M.defaultBid()
  orient = tonumber(orient) or 1
  if defined("keepScreen") then pcall(keepScreen, false) end
  if defined("syncGameScreen") then return syncGameScreen(orient, bid) end
  return false
end

function M.frontOk(bid)
  bid = bid or M.defaultBid()
  local fr = (defined("frontAppBid") and frontAppBid()) or ""
  return fr == bid
end

function M.recover(bid, orient)
  bid = bid or M.defaultBid()
  if M.frontOk(bid) then return true end
  M.log("recover reopen " .. tostring(bid))
  return M.open(bid, orient)
end

function M.screenSize()
  if defined("getScreenSize") then
    local w, h = getScreenSize()
    return tonumber(w) or 1136, tonumber(h) or 640
  end
  return 1136, 640
end

function M.snapshot(tag)
  -- 默认关闭学习截图，降低 jetsam；强制时设 __ZIYAN_ALLOW_LEARN_SNAP=true
  if _G.__ZIYAN_ALLOW_LEARN_SNAP ~= true then
    M.log("SNAP_SKIP")
    return nil
  end
  if not defined("snapshot") then return nil end
  if defined("keepScreen") then pcall(keepScreen, false) end
  if defined("mSleep") then mSleep(200) end
  local path = string.format("%s/learn_%s_%s.png", media_dir(), tostring(tag or "shot"), os.date("%H%M%S"))
  pcall(snapshot, path)
  M.log("SNAP " .. path)
  return path
end

local function color_looks_login_btn(c)
  c = tonumber(c) or 0
  local r = math.floor(c / 0x10000) % 256
  local g = math.floor(c / 0x100) % 256
  local b = c % 256
  -- 金/铜/木棕登录钮（含偏暗）
  if r > 90 and g > 55 and b < 160 and r >= g - 8 and (r - b) > 20 then
    return true
  end
  -- 拔刀木棕双联钮 0x6D552F 一类
  if r > 70 and g > 40 and r < 200 and g < 170 and b < 130 and r >= g then
    return true
  end
  return false
end

--- 按 Bundle 生成取色对照点（禁止截图；OCR 空时靠色参驱动）
function M.colorProbePoints(bid, w, h)
  bid = bid or M.defaultBid()
  w = w or select(1, M.screenSize())
  h = h or select(2, M.screenSize())
  local pts = {
    { math.floor(w * 0.50), math.floor(h * 0.50), "center" },
  }
  if bid == "com.ljzbbadao.game" then
    pts[#pts + 1] = { math.floor(w * 1103 / 2208), math.floor(h * 796 / 1242), "btn" }
    pts[#pts + 1] = { math.floor(w * 980 / 2208), math.floor(h * 796 / 1242), "btnL" }
    pts[#pts + 1] = { math.floor(w * 1220 / 2208), math.floor(h * 796 / 1242), "btnR" }
    pts[#pts + 1] = { math.floor(w * 912 / 2208), math.floor(h * 966 / 1242), "footer" }
  elseif bid == "com.xztl.ios" then
    pts[#pts + 1] = { math.floor(w * 729 / 1136), math.floor(h * 465 / 640), "btn" }
    pts[#pts + 1] = { math.floor(w * 700 / 1136), math.floor(h * 455 / 640), "btnL" }
    pts[#pts + 1] = { math.floor(w * 760 / 1136), math.floor(h * 475 / 640), "btnR" }
    pts[#pts + 1] = { math.floor(w * 0.70), math.floor(h * 0.35), "panel" }
  else
    pts[#pts + 1] = { math.floor(w * 0.50), math.floor(h * 0.64), "btn" }
    pts[#pts + 1] = { math.floor(w * 0.44), math.floor(h * 0.64), "btnL" }
    pts[#pts + 1] = { math.floor(w * 0.55), math.floor(h * 0.64), "btnR" }
  end
  return pts
end

--- 实时识字 + 命中点取色对照（禁止截图落盘）
-- 返回: hit(bool), word, x, y, color, text_sample
function M.ocrColorProbe(words, x1, y1, x2, y2)
  words = words or {}
  local bid = M.defaultBid()
  local w, h = M.screenSize()
  x1 = tonumber(x1) or 0
  y1 = tonumber(y1) or math.floor(h * 0.35)
  x2 = tonumber(x2) or (w - 1)
  y2 = tonumber(y2) or (h - 1)
  if defined("keepScreen") then pcall(keepScreen, false) end

  -- 先取色对照网格（按游戏标定；不依赖 OCR 成败）
  local color_params = {}
  local best_btn = nil
  if defined("getColor") then
    local pts = M.colorProbePoints(bid, w, h)
    for _, p in ipairs(pts) do
      local c = tonumber(getColor(p[1], p[2])) or 0
      local row = { x = p[1], y = p[2], c = c, tag = p[3] }
      color_params[#color_params + 1] = row
      M.log(string.format("COLOR_PARAM %s @%d,%d color=0x%06X", p[3], p[1], p[2], c))
      if (p[3] == "btn" or p[3] == "btnL" or p[3] == "btnR") and color_looks_login_btn(c) then
        if not best_btn or p[3] == "btn" then best_btn = row end
      end
    end
  end
  -- 记住色参供 codegen（不点触）
  if best_btn then
    M.remember(string.format("色参:%s", best_btn.tag), best_btn.x, best_btn.y,
      string.format("color:0x%06X", best_btn.c), bid)
  end

  local sample = ""
  if defined("getText") then
    local ok, a = pcall(getText, x1, y1, x2, y2)
    if ok and type(a) == "string" then sample = a end
  elseif defined("strFind") then
    local ok, a = pcall(strFind, x1, y1, x2, y2)
    if ok and type(a) == "string" then sample = a end
  end
  if #sample > 0 then
    M.log(string.format("OCR_PROBE len=%d sample=%s", #sample, sample:sub(1, 48):gsub("\n", " ")))
  else
    M.log("OCR_PROBE empty via=no_shot")
  end

  if type(findStr) == "function" then
    for _, word in ipairs(words) do
      local ok, fx, fy = pcall(findStr, word, x1, y1, x2, y2)
      if ok and fx and fx ~= -1 then
        local c = 0
        if defined("getColor") then c = tonumber(getColor(fx, fy)) or 0 end
        M.log(string.format("OCR_HIT %s @%d,%d color=0x%06X", word, fx, fy, c))
        return true, word, fx, fy, c, sample
      end
    end
  end

  local function fuzzy_hit(s, word)
    if s == "" or not word then return false end
    if s:find(word, 1, true) then return true end
    if word:find("登录") and s:find("登") then return true end
    if word:find("隐私") and (s:find("隐") or s:find("私") or s:find("惠")) then return true end
    if word:find("同意") and s:find("同") then return true end
    if word:find("进入") and s:find("进") then return true end
    return false
  end
  for _, word in ipairs(words) do
    if fuzzy_hit(sample, word) then
      local best = best_btn or color_params[2] or color_params[1]
      if best then
        M.log(string.format("OCR_TEXT_HIT %s @%d,%d color=0x%06X", word, best.x, best.y, best.c))
        return true, word, best.x, best.y, best.c, sample
      end
    end
  end

  -- OCR 空/乱码：用取色对照把「登录类」词当作色参命中（禁止截图识字）
  local want_login = false
  for _, word in ipairs(words) do
    if tostring(word):find("登", 1, true) or tostring(word):find("免密", 1, true) then
      want_login = true
      break
    end
  end
  if want_login and best_btn then
    local word = words[1] or "登录"
    M.log(string.format("COLOR_HIT %s @%d,%d color=0x%06X", word, best_btn.x, best_btn.y, best_btn.c))
    return true, word, best_btn.x, best_btn.y, best_btn.c, sample
  end

  if color_params[1] then
    M.log(string.format("COLOR_ONLY center@%d,%d color=0x%06X", color_params[1].x, color_params[1].y, color_params[1].c))
  end
  return false, nil, -1, -1, 0, sample
end

--- 内存/截屏卫生：解冻 + 清 OCR 临时，降低长时间跑 SB jetsam
function M.hygiene()
  if defined("keepScreen") then pcall(keepScreen, false) end
  _G.__ZIYAN_OCR_CACHE = nil
  pcall(function()
    os.execute(string.format(
      "rm -f '%s'/.ziyan_ocr_tmp*.png '%s'/.ziyan_dump*.png '%s'/learn_*.png '%s'/.ziyan_ocr_out.json.bak 2>/dev/null; rm -f /tmp/ziyan_*.png /var/tmp/ziyan_*.png 2>/dev/null",
      media_dir(), var_dir(), media_dir(), var_dir()))
  end)
  -- 轻量 GC 提示（Lua）
  if collectgarbage then pcall(collectgarbage, "collect") end
  M.beat()
  M.log("HYGIENE ok")
end

--- 拔刀登录：免密 (912,966) + 金钮 (1103,796) @ 2208x1242 设计分辨率缩放
function M.loginBadaoCalib(w, h)
  w = w or select(1, M.screenSize())
  h = h or select(2, M.screenSize())
  local mx, my = math.floor(w * 912 / 2208), math.floor(h * 966 / 1242)
  local gx, gy = math.floor(w * 1103 / 2208), math.floor(h * 796 / 1242)
  return mx, my, gx, gy
end

--- 拔刀一键：单次动作（免密或金钮二选一），禁止循环连点
-- 成功判定交给外层 verifyAdvance / verifyAct；本函数只触控并返回是否执行了动作
function M.loginBadao(bid, w, h)
  bid = bid or "com.ljzbbadao.game"
  w = w or select(1, M.screenSize())
  h = h or select(2, M.screenSize())
  if defined("syncScreen") then pcall(syncScreen, 1, bid) end
  local st0 = M.detectState(bid)
  M.log("badao_login pre state=" .. tostring(st0))
  if st0 == "privacy" then
    M.dismissPrivacy(bid, w, h)
    if defined("mSleep") then mSleep(600) end
    st0 = M.detectState(bid)
  end
  if st0 ~= "login" and st0 ~= "privacy" then
    return true
  end

  local function design_tap(dx, dy)
    if defined("syncTap") then
      syncTap(dx, dy, 2208, 1242)
    elseif defined("coordTap") then
      coordTap(dx, dy, 2208, 1242)
    elseif defined("tap") then
      local lx, ly = dx, dy
      if defined("coordScale") then lx, ly = coordScale(dx, dy, 2208, 1242) end
      pcall(tap, lx, ly)
    end
  end

  -- 路径A：免密一次；仍 login 再金钮一次（不同控件，非同钮连点）
  do
    local dx, dy = 880, 968
    local mx = math.floor(w * dx / 2208)
    local my = math.floor(h * dy / 1242)
    local mc = defined("getColor") and (tonumber(getColor(mx, my)) or 0) or 0
    M.log(string.format("badao_login once mianmi @%d,%d 0x%06X", mx, my, mc))
    if defined("touchDown") and defined("touchUp") then
      pcall(touchDown, 1, mx, my)
      if defined("mSleep") then mSleep(70) end
      pcall(touchUp, 1, mx, my)
      if defined("mSleep") then mSleep(120) end
      pcall(touchDown, 1, mx, my)
      if defined("mSleep") then mSleep(70) end
      pcall(touchUp, 1, mx, my)
    else
      design_tap(dx, dy)
    end
    M.remember("拔刀免密", mx, my, "badao_mianmi_once", bid)
    if defined("mSleep") then mSleep(1800) end
    if defined("syncScreen") then pcall(syncScreen, 1, bid) end
    local st_m = M.detectState(bid)
    M.log(string.format("badao_login after_mianmi state=%s front=%s",
      tostring(st_m), tostring(defined("frontAppBid") and frontAppBid() or "?")))
    if st_m ~= "login" and st_m ~= "privacy" and st_m ~= "unknown" then
      return true
    end
  end

  -- 路径B：仍 login → 金钮只点一次（密码空时预期失败，由外层验证）
  do
    local fx, fy, fc = M.findBrightGold(w * 0.35, h * 0.55, w * 0.75, h * 0.88)
    if fx ~= -1 then
      if defined("touchDown") and defined("touchUp") then
        pcall(touchDown, 1, fx, fy)
        if defined("mSleep") then mSleep(90) end
        pcall(touchUp, 1, fx, fy)
      elseif defined("tap") then
        pcall(tap, fx, fy)
      end
      M.log(string.format("badao_login once gold @%d,%d 0x%06X", fx, fy, fc))
      M.remember("拔刀登录", fx, fy, string.format("badao_gold_once:0x%06X", fc), bid)
    else
      design_tap(1103, 796)
      M.log("badao_login once gold calib 1103,796")
      M.remember("拔刀登录", math.floor(w * 1103 / 2208), math.floor(h * 796 / 1242), "badao_gold_calib", bid)
    end
  end
  -- 不在此函数内循环；不默认成功
  return false
end

--- 仙侠登录标定 @1136x640：账号框→密码框→金钮
function M.loginXztlCalib(w, h)
  w = w or select(1, M.screenSize())
  h = h or select(2, M.screenSize())
  local ax = math.floor(w * 795 / 1136)
  local ay = math.floor(h * 204 / 640)
  local px = math.floor(w * 795 / 1136)
  local py = math.floor(h * 268 / 640)
  local gx = math.floor(w * 729 / 1136)
  local gy = math.floor(h * 465 / 640)
  return ax, ay, px, py, gx, gy
end

--- 仙侠一键：单次亮金点击（经 syncTap）；禁止 3 轮连点；成功由外层验证
function M.loginXztl(bid, w, h)
  bid = bid or M.defaultBid()
  w = w or select(1, M.screenSize())
  h = h or select(2, M.screenSize())
  if defined("syncScreen") then pcall(syncScreen, 1, bid) end
  local ax, ay, px, py, gx, gy = M.loginXztlCalib(w, h)

  local function design_tap(dx, dy)
    if defined("syncTap") then
      syncTap(dx, dy, 1136, 640)
    elseif defined("coordTap") then
      coordTap(dx, dy, 1136, 640)
    elseif defined("tap") then
      local lx, ly = dx, dy
      if defined("coordScale") then lx, ly = coordScale(dx, dy, 1136, 640) end
      pcall(tap, lx, ly)
    end
  end

  local function is_bright_gold(c)
    c = tonumber(c) or 0
    local r = math.floor(c / 0x10000) % 256
    local g = math.floor(c / 0x100) % 256
    local b = c % 256
    return r > 180 and g > 120 and b < 180 and (r - b) > 50
  end

  local function gold_covered_by_white()
    if not defined("getColor") then return false end
    local c = tonumber(getColor(gx, gy)) or 0
    local r = math.floor(c / 0x10000) % 256
    local g = math.floor(c / 0x100) % 256
    local b = c % 256
    return r > 230 and g > 230 and b > 230
  end

  if gold_covered_by_white() then
    M.log("xztl_login gold_white_mask dismiss once")
    if defined("tap") then pcall(tap, math.floor(w * 0.12), math.floor(h * 0.55)) end
    if defined("mSleep") then mSleep(400) end
  end

  local c0 = defined("getColor") and (tonumber(getColor(gx, gy)) or 0) or 0
  M.log(string.format("xztl_login once pre gold=0x%06X @%d,%d", c0, gx, gy))

  -- 暗金：轻点聚焦一次（不算登录成功），再扫亮金
  if not is_bright_gold(c0) then
    design_tap(795, 268)
    if defined("mSleep") then mSleep(400) end
    c0 = defined("getColor") and (tonumber(getColor(gx, gy)) or 0) or 0
    M.log(string.format("xztl_login after_focus gold=0x%06X", c0))
  end

  local fx, fy, fc = M.findBrightGold(0.55 * w, 0.55 * h, 0.92 * w, 0.92 * h)
  if fx ~= -1 then
    if defined("touchDown") and defined("touchUp") then
      pcall(touchDown, 1, fx, fy)
      if defined("mSleep") then mSleep(90) end
      pcall(touchUp, 1, fx, fy)
    elseif defined("tap") then
      pcall(tap, fx, fy)
    end
    M.log(string.format("xztl_login once scan @%d,%d 0x%06X", fx, fy, fc))
    M.remember("仙侠登录", fx, fy, string.format("xztl_once:0x%06X", fc), bid)
  else
    design_tap(729, 465)
    M.log(string.format("xztl_login once calib @729,465 gold=0x%06X", c0))
    M.remember("仙侠登录", gx, gy, string.format("xztl_calib:0x%06X", c0), bid)
  end
  -- 不循环；不把金钮变暗当成功
  return false
end

function M.tapStep(label, x, y, via, bid)
  if not x or x == -1 then return false end
  if defined("toast") then toast(tostring(label), 800) end
  local short = tostring(via or ""):find("privacy", 1, true) ~= nil
      or tostring(label or ""):find("隐私", 1, true) ~= nil
  local function press(px, py, hold)
    hold = hold or 55
    if short and defined("tap") then
      pcall(tap, px, py)
      return
    end
    if defined("touchDown") and defined("touchUp") then
      pcall(touchDown, 1, px, py)
      if defined("mSleep") then mSleep(hold) end
      pcall(touchUp, 1, px, py)
    elseif defined("tap") then
      pcall(tap, px, py)
    end
  end
  press(x, y, short and 40 or 75)
  if not short then
    if defined("mSleep") then mSleep(180) end
    press(x, y, 70)
  end
  M.remember(label, x, y, via, bid)
  if defined("mSleep") then mSleep(short and 800 or 1500) end
  return true
end

function M.install(engine)
  _G.gameDefaultBid = M.defaultBid
  _G.gameOpen = function(bid, orient) return M.open(bid, orient) end
  _G.gameClose = function(bid) return M.close(bid) end
  _G.gameSync = function(orient, bid) return M.sync(orient, bid) end
  _G.gameLog = function(msg) return M.log(msg) end
  _G.gameBeat = function() return M.beat() end
  _G.gameRemember = function(label, x, y, via, bid) return M.remember(label, x, y, via, bid) end
  _G.gameCodegen = function(bid) return M.codegen(bid) end
  -- 规范别名：learn / codegen / saveLearned（自动生成脚本闭环）
  _G.learn = function(label, x, y, via, bid) return M.remember(label, x, y, via, bid) end
  _G.codegen = function(bid) return M.codegen(bid) end
  _G.saveLearned = function(bid) return M.saveLearned(bid) end
  _G.gameLoadLearned = function() return M.loadLearned() end
  _G.gameGetLearned = function() return M.getLearned() end
  _G.gameRecover = function(bid, orient) return M.recover(bid, orient) end
  _G.gameSnapshot = function(tag) return M.snapshot(tag) end
  _G.gameTapStep = function(label, x, y, via, bid) return M.tapStep(label, x, y, via, bid) end
  _G.gameLoginBadaoCalib = function(w, h) return M.loginBadaoCalib(w, h) end
  _G.gameLoginBadao = function(bid, w, h) return M.loginBadao(bid, w, h) end
  _G.gameLoginXztlCalib = function(w, h) return M.loginXztlCalib(w, h) end
  _G.gameLoginXztl = function(bid, w, h) return M.loginXztl(bid, w, h) end
  _G.gameDetectState = function(bid) return M.detectState(bid) end
  _G.gamePhase = function(bid) return M.phase(bid) end
  _G.gameAnalyzeFrame = function(bid) return M.analyzeFrame(bid) end
  _G.gameEnterRole = function(bid, max_steps) return M.enterRole(bid, max_steps) end
  _G.gameFindBrightGold = function(x1, y1, x2, y2) return M.findBrightGold(x1, y1, x2, y2) end
  _G.gameVerifyAdvance = function(bid, before_ph, label) return M.verifyAdvance(bid, before_ph, label) end
  _G.gameDismissPrivacy = function(bid, w, h) return M.dismissPrivacy(bid, w, h) end
  _G.gameOcrColorProbe = function(words, x1, y1, x2, y2)
    return M.ocrColorProbe(words, x1, y1, x2, y2)
  end
  _G.gameHygiene = function() return M.hygiene() end
  _G.ZiYanGame = M
  if engine then engine.game = M end
  return M
end

return M
