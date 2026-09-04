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
local BBTOUCH_REQ = ZIYAN_VAR .. "/.ziyan_bbtouch_req"
local BBTOUCH_REP = ZIYAN_VAR .. "/.ziyan_bbtouch_rep"
local APP_ALIVE = ZIYAN_VAR .. "/.ziyan_app_alive"
local PREFER_APP_TOUCH = ZIYAN_VAR .. "/.ziyan_prefer_app_touch"
local APP_TOUCH_UI = ZIYAN_VAR .. "/.ziyan_app_touch_ui"
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

--- 解析当前业务目标 BID（Home 后拉回用）；不从脚本文件名猜游戏。
local function eligible_target_bid(bid)
  bid = tostring(bid or ""):match("^%s*(.-)%s*$") or ""
  if bid == "" or bid == "com.apple.springboard" or
      bid == "com.ziyan.ziyan" or bid == "com.touchsprite.ios" then
    return ""
  end
  if #bid > 255 or not bid:match("^[%w_%-]+%.[%w_%-%.]+$") then
    return ""
  end
  return bid
end

local function target_game_bid()
  local bid = eligible_target_bid(read_line(ZIYAN_VAR .. "/.ziyan_target_bid"))
  if bid ~= "" then return bid end

  local intent = ""
  local inf = io.open(ZIYAN_VAR .. "/.ziyan_run_intent", "r")
  if inf then
    intent = inf:read("*a") or ""
    inf:close()
  end
  bid = eligible_target_bid(intent:match("[\r\n]target_bid=([^\r\n]+)") or
                             intent:match("[\r\n]bid=([^\r\n]+)"))
  if bid ~= "" then return bid end

  bid = eligible_target_bid(read_line(ZIYAN_VAR .. "/.ziyan_front_bid"))
  if bid ~= "" then
    return bid
  end
  return ""
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

-- framecap 进程没有 BKHID 注入权限；触控请求由当前前台 AppTouch
-- 短暂认领，再在目标进程内完成 down/up。
local function prefer_app_touch(on)
  if on then
    local f = io.open(PREFER_APP_TOUCH, "w")
    if not f then return false end
    f:write("1\n")
    f:close()
    return true
  end
  pcall(os.remove, PREFER_APP_TOUCH)
  return true
end

-- AppTouch 的 HID 入队只能证明事件送入 UIApplication；对 Unity/旧 UIKit
-- 页面，必须同时走 UITouch/sendEvent 分发，才能让按钮实际收到 began/ended。
-- 该标记仅在一次 tap 请求期间存在，绝不常驻抢占普通系统触控。
local function prefer_app_touch_ui(on)
  if on then
    local f = io.open(APP_TOUCH_UI, "w")
    if not f then return false end
    f:write("1\n")
    f:close()
    return true
  end
  pcall(os.remove, APP_TOUCH_UI)
  return true
end

local function ziyan_is_front(front)
  front = tostring(front or ""):lower()
  return front == "com.ziyan.ziyan"
end

local function request_ziyan_self_minimize(reason)
  pcall(function()
    local body = string.format(
      "owner=com.ziyan.ziyan\nts=%d\nsource=touch_%s\npath=\naccepted=1\n",
      os.time() or 0, tostring(reason or "guard"))
    local page = io.open(ZIYAN_VAR .. "/.ziyan_page_bg_req", "w")
    if page then
      page:write(body)
      page:close()
    end
    local home = io.open(ZIYAN_VAR .. "/.ziyan_go_home", "w")
    if home then
      home:write(body)
      home:close()
    end
  end)
end

local function front_frame_matches(front)
  front = tostring(front or "")
  if front == "" then return false end
  return read_line(ZIYAN_VAR .. "/.ziyan_front_bid") == front and
      read_line(ZIYAN_VAR .. "/.ziyan_shm_front_bid") == front and
      read_line(ZIYAN_VAR .. "/.ziyan_captured_front_bid") == front
end

local function write_tap_reject(kind, x, y, front, orient, reason)
  pcall(function()
    local f = io.open(ZIYAN_VAR .. "/.ziyan_tap_gate", "w")
    if not f then return end
    f:write(string.format(
      "ts=%d x=%s y=%s front=%s orient=%d rejected=%s kind=%s\n",
      os.time() or 0, tostring(x), tostring(y), tostring(front or ""),
      tonumber(orient) or 0, tostring(reason or "unknown"),
      tostring(kind or "touch")))
    f:close()
  end)
end

local function reject_ziyan_front_touch(kind, x, y, orient)
  local front = read_line(ZIYAN_VAR .. "/.ziyan_front_bid")
  if not ziyan_is_front(front) then
    return false, front
  end
  request_ziyan_self_minimize(kind)
  write_tap_reject(kind, x, y, front, orient, "ziyan_front")
  return true, front
end

-- 所有业务触控都只作用于当前可见前台帧。这里不按 SpringBoard/业务
-- bundle 分流；唯一例外是 ZiYan 自身仍在前台时，按最小化所有权规则拒绝本次输入。
local function current_foreground_frame(kind, x, y)
  local orient = tonumber(_G.__ZIYAN_ORIENT) or 1
  local blocked, front = reject_ziyan_front_touch(kind, x, y, orient)
  if blocked then
    return false, front, 0, 0, orient
  end
  local gen, seq = 0, 0
  pcall(function()
    local cv = package.loaded["ziyan_engine.cv"]
    if type(cv) == "table" and type(cv.vision_gate) == "function" then
      local _, snap = cv.vision_gate(kind)
      if type(snap) == "table" then
        front = tostring(snap.front_bid or front or "")
        gen = tonumber(snap.front_generation) or 0
        seq = tonumber(snap.seq) or 0
        orient = tonumber(snap.init_orient) or orient
      end
    end
  end)
  if not front_frame_matches(front) then
    write_tap_reject(kind, x, y, front, orient, "front_frame_mismatch")
    return false, front, gen, seq, orient
  end
  return true, front, gen, seq, orient
end

-- 每指最后一次 down 的逻辑坐标（touchUp(finger) 无坐标时用，避免抬在 0,0）
local _last_down = {}

local _nonce = 0
local function next_nonce()
  _nonce = _nonce + 1
  return tostring(os.time()) .. "_" .. tostring(_nonce)
end

local function wait_touch_rep(nonce, timeout_s)
  -- embed 用单调墙钟；冷路径再用有界轮询。禁止 os.clock（CPU 时间）把 1.5s
  -- 等待放大成几十秒。
  timeout_s = tonumber(timeout_s) or 0.8
  if _G.ZIYAN_LIGHT and timeout_s > 0.15 then
    timeout_s = 0.12
  end
  local native_clock = type(_G.ziyan_embed_monotonic_ms) == "function"
  local deadline_ms = nil
  if native_clock then
    local ok, now = pcall(_G.ziyan_embed_monotonic_ms)
    if ok and tonumber(now) then
      deadline_ms = tonumber(now) + timeout_s * 1000
    end
  end
  local max_spins = math.max(1, math.ceil(timeout_s * 1000))
  local spins = 0
  while spins < max_spins do
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
    if deadline_ms then
      local ok, now = pcall(_G.ziyan_embed_monotonic_ms)
      if ok and tonumber(now) and tonumber(now) >= deadline_ms then
        break
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

local function wait_bbtouch_rep(nonce, timeout_s)
  timeout_s = tonumber(timeout_s) or 1.5
  local native_clock = type(_G.ziyan_embed_monotonic_ms) == "function"
  local deadline_ms = nil
  if native_clock then
    local ok, now = pcall(_G.ziyan_embed_monotonic_ms)
    if ok and tonumber(now) then
      deadline_ms = tonumber(now) + timeout_s * 1000
    end
  end
  local max_spins = math.max(1, math.ceil(timeout_s * 1000))
  for _ = 1, max_spins do
    local r = io.open(BBTOUCH_REP, "r")
    if r then
      local lines = {}
      for line in r:lines() do lines[#lines + 1] = line end
      r:close()
      local route, down, up = "", "", ""
      for _, line in ipairs(lines) do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k == "route" then route = v
        elseif k == "down" then down = v
        elseif k == "up" then up = v
        end
      end
      if lines[1] == nonce then
        pcall(os.remove, BBTOUCH_REP)
        return lines[2] == "ok" and route == "bb" and down == "1" and up == "1"
      end
    end
    if deadline_ms then
      local ok, now = pcall(_G.ziyan_embed_monotonic_ms)
      if ok and tonumber(now) and tonumber(now) >= deadline_ms then
        break
      end
    end
    if type(_G.__ZIYAN_RAW_MSLEEP) == "function" then
      pcall(_G.__ZIYAN_RAW_MSLEEP, 1)
    elseif type(mSleep) == "function" then
      pcall(mSleep, 1)
    end
    if _ % 40 == 0 then pcall(os.execute, "sleep 0.001") end
  end
  return nil
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

local function write_bbtouch_req(body)
  local tmp = BBTOUCH_REQ .. ".tmp." ..
    tostring(math.floor((os.clock() or 0) * 1e6) % 1e8)
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(body)
  f:close()
  pcall(os.remove, BBTOUCH_REQ)
  if os.rename(tmp, BBTOUCH_REQ) then return true end
  f = io.open(BBTOUCH_REQ, "w")
  if not f then
    pcall(os.remove, tmp)
    return false
  end
  f:write(body)
  f:close()
  pcall(os.remove, tmp)
  return true
end

--- 逻辑坐标 → 触控桥（与 findMultiColor 同一 init(0/1/2)；Oc 侧 OrientMap，勿先 to_phys）
--- strict=true：超时/无回执一律失败（抬起必须严格，禁止假成功导致粘指）
local function hid_phase(phase, id, x, y, strict)
  x, y = tonumber(x) or 0, tonumber(y) or 0
  id = tonumber(id) or 1
  if phase == "down" then
    _last_down[id] = { x = x, y = y }
  end
  if _G.ZIYAN_EMBED and type(_G.ziyan_embed_touch_phase) == "function" then
    local ok, sent = pcall(_G.ziyan_embed_touch_phase, phase, id, x, y)
    if ok and sent == true then
      if phase == "up" then
        _last_down[id] = nil
      end
      return true
    end
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
    local ready, front = current_foreground_frame("down", x, y)
    if not ready then
      return false
    end
    if hid_phase("down", id, x, y) then
      _last_down[id] = { x = x, y = y, front = front }
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
    local ready, front = current_foreground_frame("move", x, y)
    if not ready then
      return false
    end
    local last = _last_down[id]
    if last and last.front and last.front ~= front then
      write_tap_reject("move", x, y, front, _G.__ZIYAN_ORIENT,
        "front_changed_during_gesture")
      return false
    end
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
      -- tap(x, y, holdMs)：前三个参数固定按坐标、时长解释。
      -- 不再根据数值大小猜测 finger，避免固定整数坐标被改写。
      return nil, a, b, c
    end
    return nil, a, b, nil -- tap(x, y)
  end

  --- 随机按压时长（毫秒），可被 tap(..., holdMs) 覆盖
  --- 8-161-60：.ziyan_light 对齐触动短按（hold~50、抬起后~30），禁 100～300ms 拖点击
  -- 默认 tap 按压时长与真人点击窗口一致；显式长按（>=200ms）仍保留。
  local TAP_HOLD_MIN, TAP_HOLD_MAX = 80, 100
  local TAP_AFTER_UP_MIN, TAP_AFTER_UP_MAX = 100, 300
  if _G.ZIYAN_LIGHT or io.open((_G.ZIYAN_VAR or "") .. "/.ziyan_light", "r") then
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
      local f = io.open(ZIYAN_VAR .. "/.ziyan_tap_meta", "w")
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

  --- 原子 tap：先把同一组逻辑坐标直接交给当前 Lua 宿主的原生 tap。
  --- 只有宿主没有原生入口时，才走设备侧请求桥；两条路径都不改坐标。
  local function hid_tap(id, x, y, holdMs)
    x, y = tonumber(x) or 0, tonumber(y) or 0
    id = math.max(1, math.min(9, math.floor(tonumber(id) or random_finger())))
    holdMs = math.floor(tonumber(holdMs) or 90)
    holdMs = math.max(TAP_HOLD_MIN, math.min(TAP_HOLD_MAX, holdMs))
    write_tap_meta(id, x, y, holdMs, 0)

    -- iOS 15+ rootless 对齐 TouchSprite 4.1.1：由常驻 daemon 自身创建
    -- IOHID system client 并直接派发。仅 framecap 内嵌宿主可走此路，
    -- 坐标继续由原生 ScreenTransform 统一映射；外部 Lua 保持原回退链。
    local isRootlessEmbed = _G.ZIYAN_EMBED
      and tostring(ZIYAN_VAR or ""):match("^/var/jb/") ~= nil
      and type(_G.ziyan_embed_tap) == "function"
    if isRootlessEmbed then
      local nativeCallOk, nativeSent =
        pcall(_G.ziyan_embed_tap, id, x, y, holdMs)
      if nativeCallOk and nativeSent == true then
        return true
      end
    end

    -- .101 真机已证实：前台 App 由 SpringBoard 当前 context 路由可产生
    -- 真实 UI 变化；BackBoard 旧进程即使回执成功也可能未消费。桌面仍走
    -- BBTouch，前台 App 先走不启用 AppTouch 的标准 touch_req。
    local front = read_line(ZIYAN_VAR .. "/.ziyan_front_bid")
    local isHome = (front == "com.apple.springboard" or front == "springboard")
    if front ~= "" and not isHome then
      local sbNonce = next_nonce()
      pcall(os.remove, TOUCH_REP)
      prefer_app_touch_ui(false)
      prefer_app_touch(false)
      local sbBody = table.concat({
        "tap", tostring(id), tostring(x), tostring(y),
        tostring(holdMs), sbNonce, ""
      }, "\n")
      if write_touch_req(sbBody) then
        local sbOk = wait_touch_rep(sbNonce, _G.ZIYAN_LIGHT and 0.35 or 1.5)
        pcall(os.remove, TOUCH_REQ)
        pcall(os.remove, TOUCH_REQ_MEDIA)
        if sbOk == true then return true end
      end
    end

    -- 桌面或标准前台路由未回执时交给 BackBoard；请求体中的 x/y
    -- 仍是调用者传入的逻辑坐标。
    -- 请求体中的 x/y 就是调用者传入值。
    local bbNonce = next_nonce()
    pcall(os.remove, BBTOUCH_REP)
    local bbBody = table.concat({
      "tap", tostring(id), tostring(x), tostring(y),
      tostring(math.floor(holdMs)), bbNonce, ""
    }, "\n")
    if write_bbtouch_req(bbBody) then
      local bbOk = wait_bbtouch_rep(bbNonce, _G.ZIYAN_LIGHT and 0.35 or 1.5)
      if bbOk == true then return true end
    end

    -- BackBoard 未回执时才让当前前台 AppTouch 兼容兜底；坐标仍原样传递。
    local appNonce = next_nonce()
    pcall(os.remove, TOUCH_REP)
    prefer_app_touch(true)
    prefer_app_touch_ui(true)
    local appBody = table.concat({
      "tap", tostring(id), tostring(x), tostring(y),
      tostring(math.floor(holdMs)), appNonce, ""
    }, "\n")
    if write_touch_req(appBody) then
      local appOk = wait_touch_rep(appNonce, _G.ZIYAN_LIGHT and 0.35 or 1.5)
      pcall(os.remove, TOUCH_REQ)
      pcall(os.remove, TOUCH_REQ_MEDIA)
      prefer_app_touch_ui(false)
      prefer_app_touch(false)
      if appOk == true then return true end
    else
      prefer_app_touch_ui(false)
      prefer_app_touch(false)
    end

    -- AppTouch 未回执时再尝试嵌入式原生入口；坐标仍原样传递。
    if _G.ZIYAN_EMBED and type(_G.ziyan_embed_tap) == "function" then
      local ok, sent = pcall(_G.ziyan_embed_tap, id, x, y, holdMs)
      if ok and sent == true then
        return true
      end
    end

    -- 最后保留旧请求桥作为兼容路径；仍然只发送这一组坐标。
    local nonce = next_nonce()
    pcall(os.remove, TOUCH_REP)
    local body = table.concat({
      "tap", tostring(id), tostring(x), tostring(y),
      tostring(math.floor(holdMs)), nonce, ""
    }, "\n")
    if not write_touch_req(body) then return false end
    local ok = wait_touch_rep(nonce, _G.ZIYAN_LIGHT and 0.35 or 1.5)
    if ok == true then return true end
    if _G.ZIYAN_LIGHT then
      local upNonce = next_nonce()
      write_touch_req(table.concat({
        "touch", "up", tostring(id), tostring(x), tostring(y), upNonce, ""
      }, "\n"))
      return false
    end
    for _ = 1, 2 do
      if hid_phase("up", id, x, y, true) then
        return false
      end
      sleep_ms(30)
    end
    return false
  end

  --- tap(x, y [, holdMs]) / tap(finger, x, y [, holdMs])
  --- 传入什么坐标就按什么坐标；找色/找图/找字坐标与固定整数共用此入口。
  function tap(a, b, c, d)
    checkpoint()
    local finger, x, y, holdMs = parse_tap_args(a, b, c, d)
    if x == nil or y == nil then
      return false
    end
    -- tap(x,y) 每次随机使用 1..9 手指 ID 和 80..100ms 按压；显式
    -- tap(finger,x,y,holdMs) 保持触动兼容语义，不覆盖调用者参数。
    finger = finger or random_finger()
    holdMs = tonumber(holdMs) or random_hold_ms()

    -- tap 只负责执行调用者给出的坐标：不以参数来源、前台或 Bundle
    -- 拒绝点击；方向映射只在底层 HID 桥内部处理。
    local front_before = read_line(ZIYAN_VAR .. "/.ziyan_front_bid")
    local gate_gen, gate_seq, gate_orient = 0, 0, tonumber(_G.__ZIYAN_ORIENT) or 1

    -- 旁路写触控契约（门禁可读）
    pcall(function()
      local f = io.open(ZIYAN_VAR .. "/.ziyan_tap_gate", "w")
      if f then
        f:write(string.format(
          "ts=%d x=%s y=%s front=%s gen=%d seq=%d orient=%d\n",
          os.time() or 0, tostring(x), tostring(y), front_before,
          gate_gen, gate_seq, gate_orient))
        f:close()
      end
    end)

    local ok = hid_tap(finger, x, y, holdMs)
    pcall(function()
      local D = _G.ZiYanCoordDiag
      if not D then
        D = dofile((_G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua") .. "/ziyan_engine/coord_diag.lua")
        if type(D) == "table" and D.install then D.install() end
      end
      if D and D.write_tap then
        D.write_tap(x, y, 1)
      end
    end)
    return ok
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
