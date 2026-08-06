-- ZiYan full business R8.4.8 keepScreen-hotpath (family=cslc imported=true)
-- app=赤沙龙城 bid=com.ychj.hlhjlygr
-- TS对齐：keepScreen(true) 一批找色共帧；tap 后 invalidate；OCR 稀触发
-- flow: boot→login→role→enter→battle→loop | color-first
local BID = "com.ychj.hlhjlygr"
local RES = { profile = "iphone7_13", family = "cslc", imported = true }
local OCR_COOL_S, LOOP_MS, SLEEP_MIN, OCR_EVERY = 8, 500, 300, 12
local deadline = os.time() + 7200
local STATE = "boot"
local LW, LH = 1136, 640
local LAST = { lab = "", t = 0 }
local HITN = {}
local LEARN_N = 0
local PHASE_DEADLINE = 0
local _ocr_last, _ocr_cache = 0, ""
local _popup_last = 0
local _frame_on = false
local _loop_tick = 0

local PHASE = {
  login = {
  {label="进入游戏", first=0xf0e2c5, off="0|1|0xf0e2c5,0|2|0xf0e2c5,0|3|0xefe2c5", degree=85, x1=535,y1=416,x2=535,y2=419},
  {label="进入游戏", first=0xe7d9be, off="0|1|0xecdec2,0|2|0xf5e7c9,0|3|0xf5e7c9", degree=85, x1=597,y1=411,x2=597,y2=414},
  {label="进入圣地判断", first=0x28ef01, off="1|0|0x28ef01,2|0|0x28ef01,3|0|0x28ef01", degree=85, x1=79,y1=100,x2=82,y2=100},
  },
  server = {
  -- empty
  },
  role = {
  {label="创建角色", first=0xd7b035, off="1|0|0xcca633,0|1|0xcca735,1|1|0xbc9a32", degree=85, x1=686,y1=392,x2=734,y2=440},
  {label="创建角色", first=0xb89630, off="1|0|0x9f832d,0|1|0x86702a,1|1|0xa0842e", degree=85, x1=716,y1=402,x2=764,y2=450},
  {label="角色选择", first=0x917050, off="0|1|0x947250,0|2|0x967552,0|3|0x977552", degree=85, x1=219,y1=473,x2=267,y2=521},
  {label="角色界面", first=0xfbfbfb, off="0|1|0xfbfbfb,0|2|0xfbfbfb,0|3|0xfbfbfb", degree=85, x1=375,y1=559,x2=423,y2=607},
  {label="角色界面", first=0xc9c9c9, off="1|0|0xcecece,2|0|0xd0d0d0,3|0|0xcfcfcf", degree=85, x1=1042,y1=0,x2=1090,y2=26},
  {label="主线角色界面", first=0xb0b0b0, off="0|1|0xb0b0b0,0|2|0xb0b0b0,0|3|0xb0b0b0", degree=85, x1=375,y1=562,x2=423,y2=610},
  {label="角色封禁", first=0xf1f1f1, off="0|1|0xf1f1f1,0|2|0xf1f1f1,0|3|0xf1f1f1", degree=85, x1=499,y1=274,x2=547,y2=322},
  {label="角色封禁", first=0xffffff, off="0|1|0xffffff,0|2|0xffffff,0|3|0xffffff", degree=85, x1=563,y1=271,x2=611,y2=319},
  },
  enter = {
  {label="进入游戏", first=0xf0e2c5, off="0|1|0xf0e2c5,0|2|0xf0e2c5,0|3|0xefe2c5", degree=85, x1=511,y1=393,x2=559,y2=441},
  {label="进入游戏", first=0xe7d9be, off="0|1|0xecdec2,0|2|0xf5e7c9,0|3|0xf5e7c9", degree=85, x1=573,y1=388,x2=621,y2=436},
  {label="进入圣地判断", first=0x28ef01, off="1|0|0x28ef01,2|0|0x28ef01,3|0|0x28ef01", degree=85, x1=56,y1=76,x2=104,y2=124},
  },
  battle = {
  {label="小助手", first=0xe6bf30, off="0|1|0xe6bf30,1|0|0xe6bf30,1|1|0xe6bf30", degree=85, x1=940,y1=58,x2=988,y2=106},
  {label="自动", first=0xd9d9d9, off="1|0|0xd2d2d2,1|1|0xd7d7d7,2|1|0xd2d2d2", degree=85, x1=1010,y1=237,x2=1058,y2=285},
  {label="自动", first=0xcdcdcd, off="0|1|0xcbcbcb,1|0|0xd4d4d4,1|1|0xb9b9b9", degree=85, x1=1024,y1=237,x2=1072,y2=285},
  {label="技能栏", first=0x242221, off="0|1|0x222121,0|2|0x232221,0|3|0x242322", degree=85, x1=1106,y1=312,x2=1154,y2=360},
  {label="技能栏", first=0x1d1c1c, off="0|1|0x1d1c1c,0|2|0x1e1d1c,0|3|0x1f1f1d", degree=85, x1=1053,y1=312,x2=1101,y2=360},
  {label="蛮荒宝库", first=0xf9e791, off="0|1|0xfae389,0|2|0xf8de83,0|3|0xf2d07a", degree=85, x1=911,y1=130,x2=959,y2=178},
  {label="设置齿轮", first=0xfefab3, off="0|1|0xfcf8ad,0|2|0xfaf7a8,0|3|0xfbf3a4", degree=85, x1=642,y1=445,x2=690,y2=493},
  {label="蛮荒宝库", first=0xf9e791, off="0|1|0xfae389,0|2|0xf8de83,0|3|0xf2d07a", degree=85, x1=911,y1=130,x2=959,y2=178},
  },
  popup = {
  -- empty
  },
}

local function sleep_ms(ms)
  if ms < SLEEP_MIN then ms = SLEEP_MIN end
  mSleep(ms)
end

local function var_dir()
  if type(ZIYAN_VAR) == "string" and #ZIYAN_VAR > 0 then return ZIYAN_VAR end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then return "/var/jb/usr/lib/ziyan/var" end
  return "/usr/lib/ziyan/var"
end

local function frame_off()
  if _frame_on and type(keepScreen) == "function" then pcall(keepScreen, false) end
  _frame_on = false
end

local function frame_on()
  if not _frame_on and type(keepScreen) == "function" then
    pcall(keepScreen, true)
    _frame_on = true
  end
end

local function after_tap()
  frame_off()
  sleep_ms(450)
end

local function screen_size()
  if type(getScreenSize) == "function" then
    local a,b = getScreenSize(); if a and b and a>0 then LW,LH=a,b end
  end
  return LW, LH
end

local function cooled(lab)
  local now = os.time()
  if lab and lab == LAST.lab and now - LAST.t < 5 then return true end
  LAST.lab = lab or ""; LAST.t = now
  return false
end

local function mark(p)
  STATE = p
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_script_phase", "w")
    if f then f:write(tostring(p) .. "\n"); f:close() end
  end)
end

local function hit_limit(lab)
  local k = tostring(lab or "")
  HITN[k] = (HITN[k] or 0) + 1
  return HITN[k] > 2
end

local function ocr_text()
  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return "" end
  local now = os.time()
  if now - _ocr_last < OCR_COOL_S then return _ocr_cache end
  _ocr_last = now
  frame_off()
  screen_size()
  local txt = ""
  if type(getText) == "function" then
    local ok, t = pcall(getText, 0, 0, -1, -1)
    if ok and t then txt = tostring(t) end
  end
  _ocr_cache = txt or ""
  return _ocr_cache
end

local function find_text_xy(word)
  frame_off(); screen_size()
  if type(findStr) == "function" then
    local ok, x, y = pcall(findStr, word, 0, 0, LW, LH)
    if ok and x and x >= 0 and y and y >= 0 then return x, y, "findStr" end
  end
  return -1, -1, nil
end

local function sample_off(x, y)
  if type(getColor) ~= "function" then return nil, nil end
  local c0 = tonumber(getColor(x, y)) or 0
  local c1 = tonumber(getColor(x + 2, y)) or c0
  local c2 = tonumber(getColor(x, y + 2)) or c0
  local c3 = tonumber(getColor(x + 2, y + 2)) or c0
  local off = string.format("2|0|0x%06X,0|2|0x%06X,2|2|0x%06X", c1, c2, c3)
  return c0, off
end

local function do_learn(label, x, y, via)
  LEARN_N = LEARN_N + 1
  if type(learn) == "function" then pcall(learn, label, x, y, via, BID)
  elseif type(gameRemember) == "function" then pcall(gameRemember, label, x, y, via, BID) end
end

local function find_one(st)
  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return -1, -1 end
  if type(findMultiColorInRegionFuzzy) ~= "function" then return -1, -1 end
  local x1,y1,x2,y2 = st.x1, st.y1, st.x2, st.y2
  if not x1 or not y1 then return -1, -1 end
  if math.abs((x2 or x1) - x1) < 8 then x1 = math.max(0, x1 - 24); x2 = x1 + 48 end
  if math.abs((y2 or y1) - y1) < 8 then y1 = math.max(0, y1 - 24); y2 = y1 + 48 end
  local x, y = findMultiColorInRegionFuzzy(st.first, st.off, st.degree or 85, x1, y1, x2, y2)
  return x or -1, y or -1
end

local function try_colors(list)
  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return false, nil, nil end
  if type(list) ~= "table" or #list == 0 then return false, nil, nil end
  frame_on(); screen_size()
  for _, st in ipairs(list) do
    local lab = tostring(st.label)
    if (HITN[lab] or 0) > 2 then goto cont_c end
    if cooled("色:" .. lab) then goto cont_c end
    local x, y = find_one(st)
    if x ~= -1 then
      if hit_limit(lab) then goto cont_c end
      toast("色:" .. lab, 500)
      tap(x, y)
      do_learn(lab, x, y, "findMulti")
      after_tap()
      return true, lab, "color"
    end
    ::cont_c::
  end
  return false, nil, nil
end

local function try_ocr_keys(ocr_keys)
  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return false, nil, nil end
  if type(ocr_keys) ~= "table" or #ocr_keys == 0 then return false, nil, nil end
  local txt = ocr_text()
  if #txt == 0 then return false, nil, nil end
  for _, w in ipairs(ocr_keys) do
    if string.find(txt, w, 1, true) then
      if cooled("OCR:" .. w) then goto cont_o end
      if hit_limit("OCR:" .. w) then goto cont_o end
      local fx, fy, via = find_text_xy(w)
      if fx >= 0 then
        toast("OCR:" .. w, 500)
        tap(fx, fy)
        local c0, off = sample_off(fx, fy)
        if c0 then
          do_learn("色参:" .. w, fx, fy, string.format("0x%06X", c0))
        end
        do_learn(w, fx, fy, via or "ocr")
        sleep_ms(700)
        return true, w, "ocr"
      end
      ::cont_o::
    end
  end
  return false, nil, nil
end

local function try_phase(list, ocr_keys)
  -- 色参优先（对齐 Ai代码训练 JH 热路径）；无色参再 OCR
  local ok, lab, via = try_colors(list)
  if ok then return ok, lab, via end
  if type(list) ~= "table" or #list == 0 then
    return try_ocr_keys(ocr_keys)
  end
  -- 有色参时 OCR 仅作兜底，且受 OCR_COOL_S 限制
  return try_ocr_keys(ocr_keys)
end

local function txt_has(txt, keys)
  for _, w in ipairs(keys) do
    if string.find(txt, w, 1, true) then return true end
  end
  return false
end

local function dismiss_popups()
  local now = os.time()
  if try_colors(PHASE.popup) then return true end
  if now - _popup_last < OCR_COOL_S then return false end
  _popup_last = now
  return try_ocr_keys({"关闭","确定","我知道了","同意","下次再说"})
end

local function ensure_front()
  local path = var_dir() .. "/.ziyan_front_bid"
  local f = io.open(path, "r")
  local front = f and f:read("*l") or ""
  if f then f:close() end
  if front == BID then return true end
  runApp(BID)
  sleep_ms(2500)
  return true
end

function phase_login()
  mark("login")
  toast("phase:login", 700)
  local t0 = os.time()
  PHASE_DEADLINE = os.time() + 25
  while os.time() - t0 < 90 do
    if os.time() - t0 > 25 then toast("phase:login:soft", 500); return true end
    ensure_front(); dismiss_popups()
    local txt = ocr_text()
    if txt_has(txt, {"进入游戏","开始游戏","选择角色","创建角色","区服"}) then return true end
    local ok, lab = try_phase(PHASE.login, {"登录","免密登录","游客登录","进入","开始游戏"})
    if ok then
      sleep_ms(900)
      txt = ocr_text()
      if not txt_has(txt, {"登录","账号","密码"}) or txt_has(txt, {"进入游戏","角色","区服"}) then return true end
    end
    if try_colors(PHASE.enter) then return true end
    if try_colors(PHASE.role) then return true end
    sleep_ms(LOOP_MS)
  end
  return true
end

function phase_role_select()
  mark("role")
  toast("phase:role", 700)
  local t0 = os.time()
  PHASE_DEADLINE = os.time() + 28
  while os.time() - t0 < 90 do
    if os.time() - t0 > 28 then toast("phase:role:soft", 500); return true end
    ensure_front(); dismiss_popups()
    local txt = ocr_text()
    if txt_has(txt, {"进入游戏","开始游戏"}) and not txt_has(txt, {"登录"}) then
      try_colors(PHASE.enter); return true
    end
    try_colors(PHASE.server)
    if try_phase(PHASE.role, {"选择角色","创建角色","角色"}) then
      sleep_ms(800)
      txt = ocr_text()
      if txt_has(txt, {"进入游戏","开始","挂机","自动"}) then return true end
    end
    if try_colors(PHASE.enter) then return true end
    sleep_ms(LOOP_MS)
  end
  return true
end

function phase_enter_game()
  mark("enter")
  toast("phase:enter", 700)
  local t0 = os.time()
  PHASE_DEADLINE = os.time() + 30
  while os.time() - t0 < 90 do
    if os.time() - t0 > 30 then toast("phase:enter:soft", 500); STATE = "main"; return true end
    ensure_front(); dismiss_popups()
    local txt = ocr_text()
    if txt_has(txt, {"挂机","自动战斗","小助手","技能"}) then STATE = "main"; return true end
    if try_phase(PHASE.enter, {"进入游戏","开始游戏","进入"}) then sleep_ms(1600); STATE = "main"; return true end
    if try_colors(PHASE.battle) then STATE = "main"; return true end
    sleep_ms(LOOP_MS)
  end
  return true
end

function phase_auto_battle()
  mark("battle")
  toast("phase:battle", 700)
  local t0 = os.time()
  local hit = false
  PHASE_DEADLINE = 0
  while os.time() - t0 < 45 do
    ensure_front()
    if os.time() - t0 > 8 then dismiss_popups() end
    -- 热路径：只色找，不每轮 OCR
    if try_colors(PHASE.battle) then hit = true; toast("loop:afk", 400) end
    sleep_ms(LOOP_MS)
    if hit and os.time() - t0 > 5 then break end
    if os.time() - t0 > 18 and not hit then
      try_ocr_keys({"挂机","自动战斗","自动"})
      toast("loop:afk", 400); break
    end
  end
  return hit
end

function check_state_and_handle()
  _loop_tick = _loop_tick + 1
  ensure_front()
  if dismiss_popups() then return end
  if try_colors(PHASE.battle) then return end
  if try_colors(PHASE.enter) then return end
  if try_colors(PHASE.role) then return end
  if _loop_tick % OCR_EVERY ~= 1 then return end
  local txt = ocr_text()
  if txt_has(txt, {"登录","账号","密码"}) then phase_login(); return end
  if txt_has(txt, {"角色","区服","选服"}) then phase_role_select(); return end
  if txt_has(txt, {"进入游戏","开始游戏"}) then phase_enter_game(); return end
end

function main()
  init(1)
  frame_off()
  screen_size()
  toast("gen-R8.4.8:" .. "赤沙龙城", 1200)
  runApp(BID)
  sleep_ms(4000)
  ensure_front()
  if type(syncGameScreen) == "function" then syncGameScreen(1, BID)
  elseif type(gameSync) == "function" then gameSync(1, BID) end
  frame_off()
  phase_login()
  phase_role_select()
  phase_enter_game()
  phase_auto_battle()
  _loop_tick = 0
  while os.time() < deadline do
    check_state_and_handle()
    sleep_ms(LOOP_MS)
  end
  frame_off()
  if type(codegen) == "function" then pcall(codegen, BID)
  elseif type(gameCodegen) == "function" then pcall(gameCodegen, BID) end
end

main()
