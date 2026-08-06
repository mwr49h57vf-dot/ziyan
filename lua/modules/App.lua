--[[ Zy.App — 应用抽象层（通用，非游戏专用）
  启动 / 关闭 / 前后台 / 窗口状态 / 运行监控
  bundlePath / dataPath 解析顺序见 bundlePath 注释。
]]
local C = require("modules._ctx")
local M = { name = "App", version = "1.1.0", layer = "abstraction" }

local function defined(n) return type(_G[n]) == "function" end

local function varDir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function shell_read(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local s = p:read("*a") or ""
  p:close()
  return s
end

local function pathExists(path)
  if path == nil or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function loadPathsCache()
  local cacheFile = varDir() .. "/.ziyan_app_paths.json"
  local f = io.open(cacheFile, "r")
  if not f then return {} end
  local raw = f:read("*a") or ""
  f:close()
  local ok, json = pcall(require, "json")
  if not ok then
    local root = (_G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua") .. "/json.lua"
    ok, json = pcall(dofile, root)
  end
  if ok and type(json) == "table" and type(json.decode) == "function" then
    local ok2, t = pcall(json.decode, raw)
    if ok2 and type(t) == "table" then return t end
  end
  return {}
end

local function bidToAppName(bid)
  bid = tostring(bid or "")
  local short = bid:match("%.([^.]+)$") or bid
  return short .. ".app"
end

--- bundlePath(bid) 解析顺序：
--- 1) ZIYAN_VAR/.ziyan_app_paths.json 缓存 bundle/data
--- 2) ZIYAN_VAR/.ziyan_app_path_<bid>.txt 单应用标记
--- 3) 越狱固定路径 /Applications/<Name>.app、/var/jb/Applications/<Name>.app
--- 4) 有限 find：/var/containers/Bundle/Application -name '*.app'（head 限 80，防阻塞）
--- 5) plutil/defaults 读已知 Info.plist（若 find 命中）
--- 失败：nil, "not_found"（不抛错）
function M.bundlePath(bid)
  bid = tostring(bid or C.bid or "")
  if bid == "" then return nil, "no_bid" end

  local cache = loadPathsCache()
  local ent = cache[bid]
  if type(ent) == "table" and type(ent.bundle) == "string" and pathExists(ent.bundle) then
    return ent.bundle
  end
  if type(ent) == "string" and pathExists(ent) then
    return ent
  end

  local flag = varDir() .. "/.ziyan_app_path_" .. bid:gsub("[^%w%.%-_]", "_") .. ".txt"
  local ff = io.open(flag, "r")
  if ff then
    local p = (ff:read("*l") or ""):gsub("%s+$", "")
    ff:close()
    if p ~= "" and pathExists(p) then return p end
  end

  local appName = bidToAppName(bid)
  local jbPaths = {
    "/Applications/" .. appName,
    "/var/jb/Applications/" .. appName,
    "/private/var/containers/Bundle/Application/" .. appName,
  }
  for _, p in ipairs(jbPaths) do
    if pathExists(p) then return p end
  end

  local listFile = varDir() .. "/.zy_bundle_find.txt"
  local cmd = string.format(
    'find /var/containers/Bundle/Application /Applications /var/jb/Applications -name "%s" 2>/dev/null | head -80 > "%s"',
    appName:gsub('"', ""), listFile:gsub('"', ""))
  pcall(os.execute, cmd)
  local lf = io.open(listFile, "r")
  if lf then
    for line in lf:lines() do
      line = (line:gsub("%s+$", ""))
      if line ~= "" and pathExists(line) then
        lf:close()
        return line
      end
    end
    lf:close()
  end

  return nil, "not_found"
end

--- dataPath(bid)：优先缓存；其次 Containers/Data 有限 find（head 限 40）
function M.dataPath(bid)
  bid = tostring(bid or C.bid or "")
  if bid == "" then return nil, "no_bid" end

  local cache = loadPathsCache()
  local ent = cache[bid]
  if type(ent) == "table" and type(ent.data) == "string" and pathExists(ent.data) then
    return ent.data
  end

  local flag = varDir() .. "/.ziyan_app_data_" .. bid:gsub("[^%w%.%-_]", "_") .. ".txt"
  local ff = io.open(flag, "r")
  if ff then
    local p = (ff:read("*l") or ""):gsub("%s+$", "")
    ff:close()
    if p ~= "" and pathExists(p) then return p end
  end

  local listFile = varDir() .. "/.zy_data_find.txt"
  local cmd = string.format(
    'find /var/mobile/Containers/Data/Application -maxdepth 2 -type d 2>/dev/null | head -40 > "%s"',
    listFile:gsub('"', ""))
  pcall(os.execute, cmd)
  -- 无 OC 时无法可靠匹配 bid→UUID；仅当 plist 可读时尝试
  local lf = io.open(listFile, "r")
  if lf then
    for line in lf:lines() do
      line = (line:gsub("%s+$", ""))
      if line ~= "" then
        local meta = line .. "/.com.apple.mobile_container_manager.metadata.plist"
        if pathExists(meta) then
          local pl = shell_read(string.format("plutil -p '%s' 2>/dev/null", meta:gsub("'", "")))
          if pl:find(bid, 1, true) then
            lf:close()
            return line
          end
        end
      end
    end
    lf:close()
  end

  return nil, "not_found"
end

function M.id(bid)
  bid = bid or C.bid
  return tostring(bid or "")
end

function M.set(bid)
  return C.set_bid(bid)
end

--- 启动应用
function M.launch(bid, wait_ms)
  bid = tostring(bid or C.bid or "")
  if bid == "" then return false, "no_bid" end
  C.set_bid(bid)
  -- 8-161-64：持久化目标 BID，供 Home 后 touch.lua 自动拉回前台（对齐触动）
  pcall(function()
    local v = _G.ZIYAN_VAR
    if type(v) ~= "string" or v == "" then
      v = io.open("/var/jb/usr/lib/ziyan/var", "r") and "/var/jb/usr/lib/ziyan/var"
          or "/usr/lib/ziyan/var"
    end
    local f = io.open(v .. "/.ziyan_target_bid", "w")
    if f then f:write(bid .. "\n"); f:close() end
  end)
  wait_ms = tonumber(wait_ms) or 2500
  local ok = false
  if defined("appRun") then ok = not not appRun(bid)
  elseif defined("runApp") then ok = not not runApp(bid)
  elseif defined("openApp") then ok = not not openApp(bid)
  end
  if defined("waitFrontApp") then
    waitFrontApp(bid, math.max(wait_ms, 3000))
  elseif defined("mSleep") then
    mSleep(wait_ms)
  end
  return ok, M.front()
end

--- 关闭应用
function M.close(bid)
  bid = tostring(bid or C.bid or "")
  if bid == "" then return false, "no_bid" end
  if defined("appKill") then return appKill(bid) end
  if defined("closeApp") then return closeApp(bid) end
  return false
end

--- 当前前台 Bundle
function M.front()
  if defined("frontAppBid") then return tostring(frontAppBid() or "") end
  if defined("frontApp") then return tostring(frontApp() or "") end
  return ""
end

--- 是否在前台
function M.isForeground(bid)
  bid = tostring(bid or C.bid or "")
  local fr = M.front()
  return fr ~= "" and fr == bid
end

--- 是否在运行（前台或进程）
function M.isRunning(bid)
  bid = tostring(bid or C.bid or "")
  if defined("appRunning") then return not not appRunning(bid) end
  return M.isForeground(bid)
end

--- 窗口/前台状态快照
function M.windowState(bid)
  bid = tostring(bid or C.bid or "")
  local fr = M.front()
  local running = M.isRunning(bid)
  local fg = (fr == bid)
  local st = "unknown"
  if not running and not fg then st = "stopped"
  elseif fg then st = "foreground"
  elseif running then st = "background"
  else st = "inactive"
  end
  return {
    bid = bid,
    front = fr,
    running = running,
    foreground = fg,
    state = st,
    ts = os.time(),
  }
end

--- 切回应用（再 launch / 等前台）
function M.activate(bid, wait_ms)
  return M.launch(bid, wait_ms)
end

--- 运行状态监控：采样 N 次
function M.monitor(bid, samples, interval_ms)
  bid = tostring(bid or C.bid or "")
  samples = tonumber(samples) or 3
  interval_ms = tonumber(interval_ms) or 400
  local hist = {}
  for i = 1, samples do
    hist[#hist + 1] = M.windowState(bid)
    if i < samples and defined("mSleep") then mSleep(interval_ms) end
  end
  return hist
end

--- 识别：仅记录 Bundle，不做游戏特判
function M.recognize()
  local fr = M.front()
  return {
    front = fr,
    known = fr ~= "" and fr ~= "com.apple.springboard",
    springboard = fr == "com.apple.springboard" or fr == "",
  }
end

--- 已安装应用列表（对齐 getInstalledApps 思想）
function M.list()
  if defined("getInstalledApps") then
    local ok, list = pcall(getInstalledApps)
    if ok and type(list) == "table" then return list end
  end
  if defined("appList") then
    local ok, list = pcall(appList)
    if ok and type(list) == "table" then return list end
  end
  local fr = M.front()
  if fr ~= "" then return { fr } end
  return {}
end

return M
