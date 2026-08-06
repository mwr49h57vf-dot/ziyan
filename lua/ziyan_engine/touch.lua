--[[ 触控：优先 AppTouch 单次 tap 协议，再 down/up；SpringBoard HID 兜底 ]]
local M = {}

-- 微抖动随机源（真人 tap）
pcall(function()
  math.randomseed((os.time() % 100000) + (os.clock() * 1000000) % 100000)
  math.random(); math.random()
end)

-- rootless=/var/jb/usr/lib/ziyan/var ；rootful=/usr/lib/ziyan/var（勿写死 rootful）
local ZIYAN_VAR = _G.ZIYAN_VAR
if type(ZIYAN_VAR) ~= "string" or ZIYAN_VAR == "" then
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    ZIYAN_VAR = "/var/jb/usr/lib/ziyan/var"
  else
    ZIYAN_VAR = "/usr/lib/ziyan/var"
  end
end
local TOUCH_REQ = ZIYAN_VAR .. "/.ziyan_touch_req"
local TOUCH_REP = ZIYAN_VAR .. "/.ziyan_touch_rep"
local APP_ALIVE = ZIYAN_VAR .. "/.ziyan_app_alive"
-- App 沙盒可读：Media 侧镜像，供 AppTouch 在游戏进程内取请求
local TOUCH_REQ_MEDIA = "/private/var/mobile/Media/ZiYan/.ziyan_touch_req"

local function defined(n) return type(_G[n]) == "function" end

local function checkpoint()
  if type(_G.__ZIYAN_wait_while_paused) == "function" then
    _G.__ZIYAN_wait_while_paused()
  end
end

local function read_line(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*l") or ""
  f:close()
  return (s:gsub("%s+$", ""))
end

--- 解析脚本目标游戏 BID（Home 后拉回用）
local function target_game_bid()
  local bid = read_line(ZIYAN_VAR .. "/.ziyan_target_bid")
  if bid ~= "" and bid ~= "com.apple.springboard" then return bid end
  bid = read_line(ZIYAN_VAR .. "/.ziyan_project_active")
  if bid ~= "" and bid:find("%.", 1, true) and not bid:find("springboard", 1, true) then
    return bid
  end
  local intent = read_line(ZIYAN_VAR .. "/.ziyan_run_intent")
  if intent:find("ios8p", 1, true) then return "com.ljzbbadao.game" end
  if intent:find("ios7", 1, true) then return "com.xztl.ios" end
  return "com.xztl.ios"
end

--- 8-161-65：禁 popen(stat)（多按 Home 后 shell 卡会死锁脚本）
--- 以 front_bid==目标 且 app_alive 文件存在为准；桌面一律 false
local function app_touch_alive()
  local bid = target_game_bid()
  local front = read_line(ZIYAN_VAR .. "/.ziyan_front_bid")
  if front ~= bid then return false end
  local f = io.open(APP_ALIVE, "r")
  if not f then return false end
  f:close()
  return true
end

--- 8-161-80：禁 open_app 系统拉起。触控始终可点（桌面图标/游戏内同一 tap API）。
local function ensure_game_for_touch()
  -- 对齐触动：不判断进程、不写 .ziyan_open_app；进游靠脚本找色+点击
  return true
end

-- 每指最后一次 down 的逻辑坐标（touchUp(finger) 无坐标时用，避免抬在 0,0）
local _last_down = {}

local _nonce = 0
local function next_nonce()
  _nonce = _nonce + 1
  return tostring(os.time()) .. "_" .. tostring(_nonce)
end

local function wait_touch_rep(nonce, timeout_s)
  -- CLI/部分宿主：mSleep / os.execute(sleep) 不可靠 → os.clock 截止（禁 os.time 整秒抬到 2s+）
  -- 8-161-61：light 对齐触动 fire-and-forget，默认 120ms；非 light 仍 ≤0.8s
  timeout_s = tonumber(timeout_s) or 0.8
  if _G.ZIYAN_LIGHT and timeout_s > 0.15 then
    timeout_s = 0.12
  end
  local t0 = os.clock() or 0
  local spins = 0
  while ((os.clock() or 0) - t0) < timeout_s do
    spins = spins + 1
    local r = io.open(TOUCH_REP, "r")
    if r then
      local n = r:read("*l")
      local st = r:read("*l")
      r:close()
      if n == nonce then
        pcall(os.remove, TOUCH_REP)
        return st == "ok"
      end
    end
    if type(_G.__ZIYAN_RAW_MSLEEP) == "function" then
      pcall(_G.__ZIYAN_RAW_MSLEEP, 1)
    elseif type(mSleep) == "function" then
      pcall(mSleep, 1)
    end
    if spins % 40 == 0 then
      pcall(os.execute, "sleep 0.001")
    end
  end
  return nil -- 超时无回执
end

local function write_touch_req(body)
  -- 原子写：避免 open("w") 截断空窗被 SB/AppTouch 误删
  local function atomic_write(path, payload)
    local tmp = path .. ".tmp." .. tostring(math.floor((os.clock() or 0) * 1e6) % 1e8)
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(payload)
    f:close()
    pcall(os.remove, path)
    if os.rename(tmp, path) then
      return true
    end
    f = io.open(path, "w")
    if not f then
      pcall(os.remove, tmp)
      return false
    end
    f:write(payload)
    f:close()
    pcall(os.remove, tmp)
    return true
  end
  local ok = atomic_write(TOUCH_REQ, body)
  -- 镜像到 Media（瞬时 IPC，消费后删除；非脚本/配置落盘）
  pcall(atomic_write, TOUCH_REQ_MEDIA, body)
  return ok
end

--- 逻辑坐标 → 触控桥（与 findMultiColor 同一 init(0/1/2)；Oc 侧 OrientMap，勿先 to_phys）
--- strict=true：超时/无回执一律失败（抬起必须严格，禁止假成功导致粘指）
local function hid_phase(phase, id, x, y, strict)
  x, y = tonumber(x) or 0, tonumber(y) or 0
  id = tonumber(id) or 1
  if phase == "down" then
    _last_down[id] = { x = x, y = y }
  end
  local nonce = next_nonce()
  pcall(os.remove, TOUCH_REP)
  local body = table.concat({
    "touch", tostring(phase), tostring(id), tostring(x), tostring(y), nonce, ""
  }, "\n")
  if not write_touch_req(body) then return false end
  local timeout = (phase == "up") and 0.8 or 0.5
  local ok = wait_touch_rep(nonce, timeout)
  if ok == true then
    if phase == "up" then
      _last_down[id] = nil
    end
    return true
  end
  if ok == false then return false end
  -- 超时：抬起绝不乐观；按下仅在 AppTouch 存活时弱成功
  if strict or phase == "up" then
    return false
  end
  return app_touch_alive()
end

local function to_phys(x, y)
  local Ori = _G.ZiYanOrient
  if Ori then
    return Ori.to_phys(x, y)
  end
  return x, y
end

function M.install()
  if type(touchDown) == "function" and not _G.__ZIYAN_RAW_TD then
    _G.__ZIYAN_RAW_TD = touchDown
    _G.__ZIYAN_RAW_TM = touchMove
    _G.__ZIYAN_RAW_TU = touchUp
  end
  local rawDown = _G.__ZIYAN_RAW_TD
  local rawMove = _G.__ZIYAN_RAW_TM
  local rawUp = _G.__ZIYAN_RAW_TU

  local function parse_args(a, b, c)
    if c == nil and b ~= nil then
      -- touchDown(x,y)：随机手指，逻辑坐标原样
      return math.random(1, 9), a, b
    end
    local id = tonumber(a) or math.random(1, 9)
    if id < 1 or id > 9 then
      id = math.random(1, 9)
    end
    return id, b, c
  end

  function touchDown(a, b, c)
    checkpoint()
    local id, x, y = parse_args(a, b, c)
    if hid_phase("down", id, x, y) then
      return true
    end
    if type(rawDown) == "function" then
      x, y = to_phys(x, y)
      return rawDown(id, x, y)
    end
    return false
  end

  function touchMove(a, b, c)
    checkpoint()
    local id, x, y = parse_args(a, b, c)
    if hid_phase("move", id, x, y) then
      return true
    end
    if type(rawMove) == "function" then
      x, y = to_phys(x, y)
      return rawMove(id, x, y)
    end
    return false
  end

  function touchUp(a, b, c)
    checkpoint()
    local id, x, y
    if b == nil then
      id = tonumber(a) or 1
      local last = _last_down[id]
      x = last and last.x or 0
      y = last and last.y or 0
      local ok = false
      for _ = 1, 3 do
        if hid_phase("up", id, x, y, true) then
          ok = true
          break
        end
        if type(mSleep) == "function" then mSleep(30) end
      end
      if type(rawUp) == "function" then
        pcall(rawUp, id)
      end
      return ok
    end
    id, x, y = parse_args(a, b, c)
    local ok = false
    for _ = 1, 3 do
      if hid_phase("up", id, x, y, true) then
        ok = true
        break
      end
      if type(mSleep) == "function" then mSleep(30) end
    end
    if ok then return true end
    if type(rawUp) == "function" then
      local px, py = to_phys(x, y)
      local rok = pcall(rawUp, id, px, py)
      if not rok then pcall(rawUp, id) end
      return true
    end
    return false
  end

  --- 解析 tap 参数
  ---   tap(x, y [, holdMs])
  ---   tap(finger, x, y [, holdMs])  finger: 1..9
  local function parse_tap_args(a, b, c, d)
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a == nil or b == nil then
      return nil
    end
    if c ~= nil and d ~= nil then
      return a, b, c, d -- finger, x, y, holdMs
    end
    if c ~= nil then
      local aInt = (a == math.floor(a)) and a >= 1 and a <= 9
      -- tap(20,20,30) → x,y,hold；tap(1,1042,270) → finger,x,y
      local maybeHold = (c >= 15 and c <= 5000 and a <= 50 and b <= 50)
      if aInt and (b > 9 or c > 9) and not maybeHold then
        return a, b, c, nil
      end
      return nil, a, b, c -- x, y, holdMs（finger 稍后随机）
    end
    return nil, a, b, nil -- x, y（finger 稍后随机）
  end

  --- 随机按压时长（毫秒），可被 tap(..., holdMs) 覆盖
  --- 8-161-60：.ziyan_light 对齐触动短按（hold~50、抬起后~30），禁 100～300ms 拖点击
  local TAP_HOLD_MIN, TAP_HOLD_MAX = 80, 100
  local TAP_AFTER_UP_MIN, TAP_AFTER_UP_MAX = 100, 300
  if _G.ZIYAN_LIGHT or io.open((_G.ZIYAN_VAR or "") .. "/.ziyan_light", "r") then
    TAP_HOLD_MIN, TAP_HOLD_MAX = 45, 70
    TAP_AFTER_UP_MIN, TAP_AFTER_UP_MAX = 20, 50
  end
  local function random_hold_ms()
    return math.random(TAP_HOLD_MIN, TAP_HOLD_MAX)
  end
  local function random_after_up_ms()
    return math.random(TAP_AFTER_UP_MIN, TAP_AFTER_UP_MAX)
  end
  local function random_finger()
    return math.random(1, 9)
  end

  local function sleep_ms(ms)
    ms = math.max(1, math.floor(tonumber(ms) or 1))
    if defined("mSleep") then
      mSleep(ms)
    else
      os.execute(string.format("sleep %.3f", ms / 1000))
    end
  end

  local function write_tap_meta(finger, x, y, holdMs, afterMs)
    pcall(function()
      local f = io.open(ZIYAN_VAR .. "/.ziyan_tap_meta", "a")
      if not f then return end
      f:write(string.format(
        "finger=%d xy=%.1f,%.1f holdMs=%d afterUpMs=%d\n",
        finger, x, y, holdMs, afterMs or 0))
      f:close()
    end)
  end

  --- 真人按下→抬起：逻辑坐标与 find 原样同一点（禁止 to_phys / 禁止偏移）
  --- 抬起必须成功：失败则重试，绝不把 down 成功当成 tap 成功
  local function human_press_lift(finger, x, y, holdMs)
    finger = math.max(1, math.min(9, math.floor(tonumber(finger) or random_finger())))
    holdMs = tonumber(holdMs)
    if holdMs == nil then
      holdMs = random_hold_ms()
    elseif holdMs > 0 and holdMs <= 10 then
      holdMs = holdMs * 1000
    end
    if holdMs < TAP_HOLD_MIN then
      holdMs = TAP_HOLD_MIN
    end
    if holdMs > TAP_HOLD_MAX and holdMs < 200 then
      holdMs = math.min(TAP_HOLD_MAX, math.max(TAP_HOLD_MIN, holdMs))
    end
    if holdMs > 5000 then
      holdMs = 5000
    end
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    local afterMs = random_after_up_ms()
    write_tap_meta(finger, x, y, holdMs, afterMs)
    hid_phase("down", finger, x, y, false)
    sleep_ms(holdMs)
    local upOk = false
    for _ = 1, 3 do
      if hid_phase("up", finger, x, y, true) then
        upOk = true
        break
      end
      sleep_ms(25)
    end
    sleep_ms(afterMs)
    return upOk, finger, x, y, x, y, holdMs
  end

  --- 原子 tap：finger / holdMs 一并交给 Oc（逻辑坐标）
  local function hid_tap(id, x, y, holdMs)
    x, y = tonumber(x) or 0, tonumber(y) or 0
    id = math.max(1, math.min(9, math.floor(tonumber(id) or random_finger())))
    holdMs = tonumber(holdMs) or random_hold_ms()
    if holdMs < TAP_HOLD_MIN then holdMs = TAP_HOLD_MIN end
    if holdMs > TAP_HOLD_MAX and holdMs < 200 then
      holdMs = TAP_HOLD_MAX
    end
    local afterMs = random_after_up_ms()
    write_tap_meta(id, x, y, holdMs, afterMs)
    local nonce = next_nonce()
    pcall(os.remove, TOUCH_REP)
    local body = table.concat({
      "tap", tostring(id), tostring(x), tostring(y),
      tostring(math.floor(holdMs)), nonce, ""
    }, "\n")
    if not write_touch_req(body) then return false end
    -- 8-161-61：light 触动式 — 写完即算发出（AppTouch 无回执时旧路径可堵 15s）
    local ok = wait_touch_rep(nonce, _G.ZIYAN_LIGHT and 0.12 or 1.5)
    sleep_ms(afterMs)
    if ok == true then return true end
    if _G.ZIYAN_LIGHT then
      -- 无回执：补一条 up 文件（不等待），防粘指；不进入 human_press_lift 风暴
      local upNonce = next_nonce()
      write_touch_req(table.concat({
        "touch", "up", tostring(id), tostring(x), tostring(y), upNonce, ""
      }, "\n"))
      return true
    end
    for _ = 1, 2 do
      if hid_phase("up", id, x, y, true) then
        return false -- 原子失败但已抬起，避免粘指
      end
      sleep_ms(30)
    end
    return false
  end

  --- tap(x, y [, holdMs]) / tap(finger, x, y [, holdMs])
  --- 与 find 返回同一逻辑点；对齐 TS：优先原子 tap（一次 down+up）
  function tap(a, b, c, d)
    checkpoint()
    local finger, x, y, holdMs = parse_tap_args(a, b, c, d)
    if x == nil or y == nil then
      return false
    end
    if finger == nil then
      finger = random_finger()
    end
    if holdMs == nil then
      holdMs = random_hold_ms()
    end

    -- Home / 回桌面：先拉回游戏再点（否则 thin 路径 touch_req 无人消费）
    ensure_game_for_touch()

    local ok = hid_tap(finger, x, y, holdMs)
    pcall(function()
      local D = _G.ZiYanCoordDiag
      if not D then
        D = dofile((_G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua") .. "/ziyan_engine/coord_diag.lua")
        if type(D) == "table" and D.install then D.install() end
      end
      if D and D.write_tap then
        -- 主路径逻辑原样下发：transform_count=1（Oc 侧唯一 OrientMap）
        D.write_tap(x, y, 1)
      end
    end)
    if ok then
      return true
    end
    -- 8-161-61：light 已 fire-and-forget，禁止再走 human_press_lift（每 phase 再等 0.8s×N）
    if _G.ZIYAN_LIGHT then
      return true
    end
    ok = human_press_lift(finger, x, y, holdMs)
    if ok then
      return true
    end

    if type(rawDown) == "function" then
      local px, py = to_phys(x, y)
      pcall(function()
        local D = _G.ZiYanCoordDiag
        if D and D.write_tap then D.write_tap(x, y, 2) end -- fallback 二次 to_phys
      end)
      pcall(rawDown, finger, px, py)
      sleep_ms(holdMs)
      if type(rawUp) == "function" then
        local uok = pcall(rawUp, finger, px, py)
        if not uok then
          pcall(rawUp, finger)
        end
      end
      -- 再补 HID up，防 TE/HID 混用粘指
      hid_phase("up", finger, x, y, true)
    end
    return false
  end

  if not defined("moveTo") then
    function moveTo(x1, y1, x2, y2, step, ms)
      step = step or 10
      ms = ms or 50
      touchDown(1, x1, y1)
      if defined("mSleep") then mSleep(20) end
      local dx, dy = x2 - x1, y2 - y1
      local n = math.max(1, math.floor(math.max(math.abs(dx), math.abs(dy)) / math.max(step, 1)))
      for i = 1, n do
        touchMove(1, x1 + dx * i / n, y1 + dy * i / n)
        if defined("mSleep") then
          mSleep(math.max(1, math.floor(ms / n)))
        end
      end
      touchUp(1, x2, y2)
    end
  end

  --- 滑动：逻辑坐标（与 tap 同一套）
  function swipe(x1, y1, x2, y2, duration_ms)
    checkpoint()
    x1, y1 = tonumber(x1) or 0, tonumber(y1) or 0
    x2, y2 = tonumber(x2) or 0, tonumber(y2) or 0
    duration_ms = tonumber(duration_ms) or 400
    local dist = math.max(math.abs(x2 - x1), math.abs(y2 - y1), 1)
    local step = math.max(4, math.floor(dist / 20))
    local n = math.max(1, math.floor(dist / step))
    local ms = math.max(1, math.floor(duration_ms / n))
    moveTo(x1, y1, x2, y2, step, ms)
    return true
  end

  _G.__ZIYAN_TOUCH_HID = true
  return M
end

return M
