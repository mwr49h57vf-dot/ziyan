--[[ 应用：经 SpringBoard IPC 打开/关闭（对齐「先开游再做事」习惯，自有实现） ]]
local M = {}

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

local function write_ipc(name, body)
  local path = var_dir() .. "/" .. name
  local f = io.open(path, "w")
  if not f then return false end
  f:write(tostring(body or ""))
  f:close()
  return true
end

local function read_line(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*l") or ""
  f:close()
  return (s:gsub("%s+$", ""))
end

local function sleep_ms(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then return end
  if defined("mSleep") then
    mSleep(ms)
  else
    os.execute(string.format("sleep %.3f", ms / 1000))
  end
end

--- 当前前台 bundle（SpringBoard 写入 .ziyan_front_bid）
function frontAppBid()
  return read_line(var_dir() .. "/.ziyan_front_bid")
end

function frontApp()
  return frontAppBid()
end

--- 进程是否在跑：前台匹配或 ps 兜底
function appRunning(bid)
  bid = tostring(bid or "")
  if bid == "" then return false end
  if frontAppBid() == bid then return true end
  local ok = false
  pcall(function()
    local p = io.popen(string.format(
      "ps aux 2>/dev/null | grep -F '%s' | grep -v grep | head -1", bid))
    if p then
      local line = p:read("*l")
      p:close()
      ok = type(line) == "string" and #line > 0
    end
  end)
  return ok
end

function M.install()
  local nativeAppRun = defined("appRun") and appRun or nil
  local nativeAppKill = defined("appKill") and appKill or nil

  function appRun(bid)
    bid = tostring(bid or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if bid == "" then return false end
    if write_ipc(".ziyan_open_app", bid .. "\n") then
      sleep_ms(400)
      if type(nativeAppRun) == "function" then
        pcall(nativeAppRun, bid)
      end
      return true
    end
    if type(nativeAppRun) == "function" then
      local ok, r = pcall(nativeAppRun, bid)
      if ok and r then return true end
    end
    os.execute(string.format("uiopen '%s://' >/dev/null 2>&1 &", bid))
    return true
  end

  function runApp(bid)
    return appRun(bid)
  end

  function openApp(bid)
    return appRun(bid)
  end

  function waitFrontApp(bid, timeoutMs)
    bid = tostring(bid or "")
    timeoutMs = tonumber(timeoutMs) or 8000
    local t0 = os.clock()
    while (os.clock() - t0) * 1000 < timeoutMs do
      if frontAppBid() == bid then
        return true
      end
      sleep_ms(200)
    end
    return frontAppBid() == bid
  end

  function appKill(bid)
    bid = tostring(bid or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if bid == "" then return false end
    write_ipc(".ziyan_close_app", bid .. "\n")
    sleep_ms(300)
    if type(nativeAppKill) == "function" then
      pcall(nativeAppKill, bid)
    end
    local leaf = bid:match("[^%.]+$") or bid
    os.execute(string.format("killall '%s' >/dev/null 2>&1", leaf))
    os.execute(string.format("killall -9 '%s' >/dev/null 2>&1", leaf))
    return true
  end

  function closeApp(bid, flag)
    return appKill(bid)
  end

  --- 开游 → 等前台 → 同步逻辑屏
  function runAppAndSync(bid, orient, waitMs)
    orient = tonumber(orient)
    if orient == nil then
      orient = tonumber(_G.__ZIYAN_ORIENT) or 1
    end
    waitMs = tonumber(waitMs) or 2000
    local ok = appRun(bid)
    waitFrontApp(bid, math.max(waitMs, 3000))
    sleep_ms(waitMs)
    if type(syncGameScreen) == "function" then
      syncGameScreen(orient, bid)
    elseif type(init) == "function" then
      init(orient)
    end
    return ok
  end

  _G.__ZIYAN_NATIVE_APP_RUN = nativeAppRun
  _G.__ZIYAN_NATIVE_APP_KILL = nativeAppKill
  _G.frontAppBid = frontAppBid
  _G.frontApp = frontApp
  _G.appRunning = appRunning
  return M
end

return M
