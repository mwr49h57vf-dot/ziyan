--[[ 设备 / 环境：识别 · 设备库 · 解锁 · 路径 · 剪贴板
  阶段2：Device 加厚 — 型号/系统/arch/分辨率/DPI/安全区/游戏区
]]
local ZIYAN = "/private/var/mobile/Media/ZiYan"
local M = { module = "device", version = "2.0.0" }

local function defined(n) return type(_G[n]) == "function" end
local function ensure(name, fn)
  if not defined(name) then _G[name] = fn end
end

local function resolve_var()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function sleep_ms(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then return end
  if type(mSleep) == "function" then
    mSleep(ms)
  else
    os.execute(string.format("sleep %.3f", ms / 1000))
  end
end

local function read_lines(path, n)
  local f = io.open(path, "r")
  if not f then return {} end
  local t = {}
  for i = 1, (n or 8) do
    local line = f:read("*l")
    if not line then break end
    t[#t + 1] = line
  end
  f:close()
  return t
end

local function shell_one(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local s = p:read("*l") or ""
  p:close()
  return (s:gsub("%s+$", ""))
end

local function is_rootless()
  return io.open("/var/jb/usr/lib/ziyan/var", "r") ~= nil
      or io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") ~= nil
end

local function approx_dpi(native_w, scale)
  -- 常见点宽 ≈ native/scale；粗估 PPI
  local points = (tonumber(native_w) or 640) / math.max(tonumber(scale) or 2, 1)
  if points >= 400 then return 460 end
  if points >= 370 then return 401 end
  if points >= 300 then return 326 end
  return 264
end

local function safe_insets(logic_w, logic_h, orient)
  -- 可配置覆盖；默认按横竖给保守安全区（点→逻辑像素近似）
  orient = tonumber(orient) or 1
  local top, bottom, left, right = 0, 0, 0, 0
  if orient == 0 then
    top, bottom = math.floor((logic_h or 1136) * 0.04), math.floor((logic_h or 1136) * 0.03)
  else
    left, right = math.floor((logic_w or 1136) * 0.03), math.floor((logic_w or 1136) * 0.02)
    top, bottom = math.floor((logic_h or 640) * 0.02), math.floor((logic_h or 640) * 0.02)
  end
  return { top = top, bottom = bottom, left = left, right = right }
end

--- 构建当前设备画像（不写死游戏 Bundle）
function M.profile()
  local var = resolve_var()
  local native = read_lines(var .. "/.ziyan_native_wh", 3)
  local orient_lines = read_lines(var .. "/.ziyan_orient", 3)
  local nw = tonumber(native[1]) or 0
  local nh = tonumber(native[2]) or 0
  local scale = tonumber(native[3]) or 0
  if nw < 1 or nh < 1 then
    -- 回退：逻辑尺寸反推竖屏原生
    local lw, lh = 1136, 640
    if defined("getScreenSize") then
      lw, lh = getScreenSize()
      lw, lh = tonumber(lw) or 1136, tonumber(lh) or 640
    end
    if lw >= lh then
      nw, nh = lh, lw
    else
      nw, nh = lw, lh
    end
  end
  if scale < 1 then
    if nw >= 1080 then scale = 3
    elseif nw >= 700 then scale = 2
    else scale = 2 end
  end

  local orient = tonumber(orient_lines[1]) or tonumber(_G.__ZIYAN_ORIENT) or 1
  local lw = tonumber(orient_lines[2]) or 0
  local lh = tonumber(orient_lines[3]) or 0
  if lw < 1 or lh < 1 then
    if defined("getScreenSize") then
      lw, lh = getScreenSize()
    end
    lw, lh = tonumber(lw) or 1136, tonumber(lh) or 640
  end

  local model = shell_one("uname -m")
  if model == "" then model = "unknown" end
  local hw = shell_one("sysctl -n hw.machine")
  if hw == "" then hw = shell_one("uname -n") end
  local osver = shell_one("sw_vers -productVersion")
  if osver == "" then
    osver = shell_one("uname -r")
  end
  -- 宿主探测文件（双机兼容冒烟写入，非 Media）
  do
    local hint = io.open(var .. "/.ziyan_device_hint", "r")
    if hint then
      local body = hint:read("*a") or ""
      hint:close()
      local m = body:match("machine=([%w,]+)")
      local o = body:match("ios=([0-9.]+)")
      local c = body:match("cpu_n=(%d+)")
      if m and #m > 0 then hw = m end
      if o and #o > 0 then osver = o end
      if c then
        -- stash for later
        _G.__ZIYAN_HINT_CPU_N = tonumber(c)
      end
    end
  end
  -- SB 侧已写的屏幕信息（沙盒下 shell 可能空）
  do
    local info = read_lines(var .. "/.ziyan_screen_info", 1)
    local line = info[1] or ""
    if hw == "" or hw == "unknown" or hw == "iPhone" then
      local m = line:match("model=([%w,]+)") or line:match("machine=([%w,]+)")
      if m then hw = m end
    end
    if osver == "" then
      local o = line:match("os=([0-9.]+)") or line:match("ios=([0-9.]+)")
      if o then osver = o end
    end
  end
  -- 设备库旧值回填
  do
    local db = io.open(var .. "/device_db.json", "r")
    if db then
      local body = db:read("*a") or ""
      db:close()
      if (hw == "" or hw == "unknown" or hw == "iPhone") then
        local m = body:match('"model"%s*:%s*"([^"]+)"')
        if m and m ~= "unknown" and not m:match("^iOS%-") then hw = m end
      end
      if osver == "" or osver:match("^darwin") then
        local o = body:match('"os"%s*:%s*"([^"]+)"')
        if o and #o > 0 and not o:match("^darwin") then osver = o end
      end
    end
  end
  -- 沙盒下 shell 常空：用 native 分辨率指纹作稳定机型键（仅当仍无 ProductType）
  if hw == "" or hw == "unknown" or hw == model or hw == "iPhone" then
    hw = string.format("iOS-%dx%d@%.0f", nw, nh, scale)
  end
  if osver == "" or osver == "unknown" then
    osver = string.format("darwin-scale%.0f", scale)
  end
  local arch = "arm"
  if model:find("arm64", 1, true) or hw:find("iPhone1[0-9]", 1) or is_rootless() then
    arch = "arm64"
  end
  -- 更稳：读进程 arch 文件若有
  if io.open("/var/jb", "r") then arch = "arm64" end
  if hw:find("iPhone9", 1, true) or hw:find("iPhone10", 1, true) then
    arch = "arm64"
  end

  local dpi = approx_dpi(nw, scale)
  local insets = safe_insets(lw, lh, orient)
  local game = {
    x = insets.left,
    y = insets.top,
    w = math.max(1, lw - insets.left - insets.right),
    h = math.max(1, lh - insets.top - insets.bottom),
  }

  local cpu = shell_one("sysctl -n hw.ncpu")
  if (not cpu or cpu == "") and _G.__ZIYAN_HINT_CPU_N then
    cpu = tostring(_G.__ZIYAN_HINT_CPU_N)
  end
  local cpu_brand = shell_one("sysctl -n machdep.cpu.brand_string")
  if cpu_brand == "" then cpu_brand = shell_one("sysctl -n hw.model") end

  local prof = {
    model = hw ~= "" and hw or model,
    uname_m = model,
    product = hw,
    os = osver,
    arch = arch,
    rootless = is_rootless(),
    native_w = nw,
    native_h = nh,
    scale = scale,
    logic_w = lw,
    logic_h = lh,
    orient = orient,
    dpi = dpi,
    cpu_n = tonumber(cpu) or 0,
    cpu = (cpu_brand ~= "" and cpu_brand)
      or ((cpu ~= "" and cpu) and ("ncpu=" .. tostring(cpu)))
      or "",
    gpu = "unknown", -- 真机侧无稳定公开 API；禁止编造
    safe = insets,
    game_rect = game,
    var = var,
    scripts = ZIYAN,
    ts = os.time(),
  }
  _G.__ZIYAN_DEVICE_PROFILE = prof
  return prof
end

--- Device Model 别名
function M.model()
  return M.profile()
end

function M.refresh()
  return M.profile()
end

function M.game_rect()
  local p = _G.__ZIYAN_DEVICE_PROFILE
  if type(p) ~= "table" or type(p.game_rect) ~= "table" then
    p = M.profile()
  end
  local g = p.game_rect
  return g.x, g.y, g.w, g.h
end

local function profile_json(p)
  return string.format(
    "{\n  \"model\":%q,\n  \"os\":%q,\n  \"arch\":%q,\n  \"rootless\":%s,\n"
      .. "  \"native_w\":%d,\n  \"native_h\":%d,\n  \"scale\":%.2f,\n"
      .. "  \"logic_w\":%d,\n  \"logic_h\":%d,\n  \"orient\":%d,\n  \"dpi\":%d,\n"
      .. "  \"cpu\":%q,\n  \"cpu_n\":%d,\n  \"gpu\":%q,\n"
      .. "  \"game_rect\":{\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d},\n  \"ts\":%d\n}\n",
    tostring(p.model), tostring(p.os), tostring(p.arch),
    p.rootless and "true" or "false",
    p.native_w, p.native_h, p.scale,
    p.logic_w, p.logic_h, p.orient, p.dpi,
    tostring(p.cpu or ""), tonumber(p.cpu_n) or 0, tostring(p.gpu or "unknown"),
    p.game_rect.x, p.game_rect.y, p.game_rect.w, p.game_rect.h, p.ts)
end

function M.save_profile()
  local p = M.profile()
  local body = profile_json(p)
  local var_path = resolve_var() .. "/device_db.json"
  -- Media/ZiYan 仅允许用户脚本；设备库只写 var（禁止 device_model.json 污染脚本目录）
  local f = io.open(var_path, "w")
  if f then
    f:write(body)
    f:close()
    return true, var_path
  end
  return false, var_path
end

--- 无密码解锁：写 .ziyan_unlock_req → SpringBoard 亮屏+解锁（显式请求，SB 必响应）
local function request_unlock()
  local var = resolve_var()
  -- 顺带标记项目活跃，便于 SB 崩溃重启后自动再解
  pcall(function()
    local af = io.open(var .. "/.ziyan_project_active", "w")
    if af then af:write(tostring(os.time()) .. "\n"); af:close() end
  end)
  pcall(os.remove, var .. "/.ziyan_unlock_rep")
  local f = io.open(var .. "/.ziyan_unlock_req", "w")
  if not f then
    return false
  end
  f:write("1\n")
  f:close()
  for _ = 1, 40 do
    local r = io.open(var .. "/.ziyan_unlock_rep", "r")
    if r then
      local body = r:read("*a") or ""
      r:close()
      pcall(os.remove, var .. "/.ziyan_unlock_rep")
      return body:find("ok", 1, true) ~= nil or body:find("\n1", 1, true) ~= nil
    end
    sleep_ms(50)
  end
  return true
end

function M.install()
  ensure("userPath", function()
    return ZIYAN
  end)
  ensure("unlockDevice", function(pass)
    return request_unlock()
  end)
  ensure("deviceUnlock", function(pass)
    return request_unlock()
  end)
  ensure("deviceIsLock", function()
    local var = resolve_var()
    local f = io.open(var .. "/.ziyan_lock_state", "r")
    if f then
      local v = tonumber((f:read("*l") or ""):match("%d+")) or 0
      f:close()
      return v
    end
    return 0
  end)
  ensure("writePasteboard", function(text)
    if defined("CopyClipboard") then
      return CopyClipboard(text)
    end
    if defined("copyText") then
      return copyText(text)
    end
    return false
  end)
  ensure("readPasteboard", function()
    if defined("PasteClipboard") then
      return PasteClipboard()
    end
    return ""
  end)
  ensure("getNetIP", function()
    if defined("NetIp") then
      return NetIp()
    end
    return ""
  end)
  ensure("setWifiEnable", function(on)
    -- Wave3：写 SB 请求；具体开关由 ScreenBridge.pollDeviceControl 执行
    local var = resolve_var()
    local v = (on == true or on == 1 or on == "1" or on == "true") and "1" or "0"
    local f = io.open(var .. "/.ziyan_wifi_enable_req", "w")
    if not f then return false end
    f:write(v .. "\n")
    f:close()
    return true
  end)
  ensure("showUI", function(jsonStr)
    if defined("toast") then
      toast("无配置窗，使用默认/已有配置", 1200)
    end
    return 0
  end)
  ensure("lua_exit", function()
    if defined("scriptStop") then
      scriptStop()
    else
      os.exit()
    end
  end)
  ensure("nLog", function(...)
    if defined("logDebug") then
      local t = {}
      for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
      logDebug(table.concat(t, " "))
    end
  end)

  -- 阶段2：Device 识别 API
  _G.deviceProfile = function() return M.profile() end
  _G.deviceModel = function() return M.model() end
  _G.deviceRefresh = function() return M.refresh() end
  _G.deviceGameRect = function() return M.game_rect() end
  _G.deviceSaveProfile = function() return M.save_profile() end
  _G.ZiYanDevice = M

  -- 启动时刷新一次画像（失败不阻断）
  pcall(M.profile)

  return M
end

return M
