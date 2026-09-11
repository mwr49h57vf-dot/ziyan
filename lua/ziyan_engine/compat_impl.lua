--[[
  ziyan_engine/compat_impl.lua
  ------------------------------------------------------------
  TS 文档函数名的 ZiYan 自研实现后端（不调用触动私有 API）。
  由 compat_registry.lua 按名一一 bind。
]]
local M = { name = "compat_impl", version = "1.3.0" }

-- 仅认真实底层 / 显式 native 快照；不认 compat 包装，避免递归
local function native(name)
  local tag = "__ZIYAN_NATIVE_" .. name
  local n = rawget(_G, tag)
  if type(n) == "function" then return n end
  local g = rawget(_G, name)
  if type(g) == "function" and rawget(_G, "__ZIYAN_COMPAT_WRAP_" .. name) ~= true then
    return g
  end
  return nil
end

local function defined(n)
  return type(native(n)) == "function"
end

local function nyi(tag)
  return false, "not_implemented:" .. tostring(tag or "?")
end

local function unsupported(tag)
  return false, "unsupported:" .. tostring(tag or "?")
end

----------------------------------------------------------------------
-- color
----------------------------------------------------------------------
local color = {}

function color.getColor(x, y)
  if type(_G.Zy) == "table" and _G.Zy.Vision and type(_G.Zy.Vision.getColor) == "function" then
    return _G.Zy.Vision.getColor(x, y)
  end
  local n = native("getColor")
  if n then return n(x, y) end
  return -1
end

function color.getColorRGB(x, y)
  local c = color.getColor(x, y)
  c = tonumber(c) or 0
  if c < 0 then return 0, 0, 0 end
  local r = math.floor(c / 0x10000) % 256
  local g = math.floor(c / 0x100) % 256
  local b = c % 256
  return r, g, b
end

function color.intToRgb(c)
  c = tonumber(c) or 0
  return math.floor(c / 0x10000) % 256, math.floor(c / 0x100) % 256, c % 256
end

function color.rgbToInt(r, g, b)
  r, g, b = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
  return r * 0x10000 + g * 0x100 + b
end

function color.toTableType(s)
  if type(s) == "table" then return s end
  s = tostring(s or "")
  local t = {}
  for part in string.gmatch(s, "[^,]+") do
    local dx, dy, col = part:match("([^|]+)|([^|]+)|(.+)")
    if dx then
      t[#t + 1] = { tonumber(dx) or 0, tonumber(dy) or 0, tonumber(col) or 0 }
    else
      t[#t + 1] = tonumber(part) or 0
    end
  end
  return t
end

function color.toStringType(t)
  if type(t) ~= "table" then return tostring(t or "") end
  local parts = {}
  for _, v in ipairs(t) do
    if type(v) == "table" then
      parts[#parts + 1] = string.format("%s|%s|0x%06x", tostring(v[1] or 0), tostring(v[2] or 0), tonumber(v[3] or 0) or 0)
    else
      parts[#parts + 1] = string.format("0x%06x", tonumber(v) or 0)
    end
  end
  return table.concat(parts, ",")
end

function color.isColor(x, y, c, sim)
  local got = color.getColor(x, y)
  c = tonumber(c) or 0
  sim = tonumber(sim) or 90
  if got < 0 then return false end
  if sim >= 100 then return got == c end
  local r1, g1, b1 = color.intToRgb(got)
  local r2, g2, b2 = color.intToRgb(c)
  local thr = math.floor((100 - sim) * 2.55)
  return math.abs(r1 - r2) <= thr and math.abs(g1 - g2) <= thr and math.abs(b1 - b2) <= thr
end

function color.isColors(points, sim)
  if type(points) ~= "table" then return false end
  for _, p in ipairs(points) do
    local x = p[1] or p.x
    local y = p[2] or p.y
    local c = p[3] or p.color
    if not color.isColor(x, y, c, sim) then return false end
  end
  return true
end

function color.multiColor(points, sim)
  return color.isColors(points, sim)
end

function color.muColors(groups, sim)
  if type(groups) ~= "table" then return false, -1 end
  for i, g in ipairs(groups) do
    if color.isColors(g, sim) then return true, i end
  end
  return false, -1
end

function color.multiColTap(points, sim)
  if color.multiColor(points, sim) then
    local p = points[1]
    local x, y = p[1] or p.x, p[2] or p.y
    do local __n=native("tap"); if __n then __n(x, y) end end
    return true
  end
  return false
end

-- 与抓色器一致：main + "dx|dy|0x.." + degree + ROI → x,y
local function find_multi(main, offset, degree, x1, y1, x2, y2)
  local n = native("findMultiColorInRegionFuzzy")
  if n then
    local x, y = n(main, offset or "", degree or 90, x1, y1, x2, y2)
    return tonumber(x) or -1, tonumber(y) or -1
  end
  if type(_G.Zy) == "table" and _G.Zy.Vision then
    local v = _G.Zy.Vision
    if type(v.findMultiColorInRegionFuzzy) == "function" then
      local x, y = v.findMultiColorInRegionFuzzy(main, offset, degree, x1, y1, x2, y2)
      return tonumber(x) or -1, tonumber(y) or -1
    end
    if type(v.findMultiColor) == "function" then
      local x, y = v.findMultiColor(main, offset, degree, x1, y1, x2, y2)
      return tonumber(x) or -1, tonumber(y) or -1
    end
  end
  return -1, -1
end

function color.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
  return find_multi(a, b, c, d, e, f, g)
end

function color.findMultiColor(a, b, c, d, e, f, g)
  return find_multi(a, b, c, d, e, f, g)
end

function color.findMultiColorInRegionFuzzyExt(a, b, c, d, e, f, g)
  return find_multi(a, b, c, d, e, f, g)
end

function color.findMultiColorInRegionFuzzyByTable(tbl, degree, x1, y1, x2, y2)
  if type(tbl) ~= "table" then return -1, -1 end
  -- 支持抓色器风格：{ main=0x.., offset="dx|dy|0x.." } 或 {0x主色, "偏点串"}
  local main = tbl.main or tbl.first or tbl[1] or 0
  local off = tbl.offset or tbl.posandcolors or tbl[2] or ""
  if type(off) == "table" then off = color.toStringType(off) end
  if type(off) ~= "string" then off = "" end
  return find_multi(main, off, degree or tbl.degree or 90, x1 or 0, y1 or 0, x2 or -1, y2 or -1)
end

function color.findColorInRegionFuzzy(c, degree, x1, y1, x2, y2)
  return find_multi(c, "", degree or 90, x1, y1, x2, y2)
end

function color.findColor(c, degree)
  return color.findColorInRegionFuzzy(c, degree, 0, 0, -1, -1)
end

function color.findColorUntil(c, degree, timeout_ms, interval)
  timeout_ms = tonumber(timeout_ms) or 3000
  interval = tonumber(interval) or 200
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < timeout_ms do
    local x, y = color.findColor(c, degree)
    if x ~= -1 then return x, y end
    do local __n=native("mSleep"); if __n then __n(interval) end end
  end
  return -1, -1
end

function color.findColorsUntil(main, offset, degree, x1, y1, x2, y2, timeout_ms, interval)
  timeout_ms = tonumber(timeout_ms) or 3000
  interval = tonumber(interval) or 200
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < timeout_ms do
    local x, y = find_multi(main, offset, degree, x1, y1, x2, y2)
    if x ~= -1 then return x, y end
    do local __n=native("mSleep"); if __n then __n(interval) end end
  end
  return -1, -1
end

function color.setColor(...)
  return nyi("setColor")
end

function color.replaceColor(...)
  return nyi("replaceColor")
end

----------------------------------------------------------------------
-- touch / screen / time / input / keycode / app / file / log / device
----------------------------------------------------------------------
local function time_m_mSleep(ms)
  local n = native("mSleep")
  if n then return n(ms) end
  local t0 = os.clock()
  local sec = (tonumber(ms) or 0) / 1000
  while os.clock() - t0 < sec do end
end

local touch = {}
function touch.tap(x, y)
  local n = native("tap")
  if n then return n(x, y) end
  if type(_G.Zy) == "table" and _G.Zy.Touch and type(_G.Zy.Touch.tap) == "function" then
    return _G.Zy.Touch.tap(x, y)
  end
  return nyi("tap")
end
function touch.touchDown(id, x, y)
  local n = native("touchDown")
  if n then return n(id, x, y) end
  return nyi("touchDown")
end
function touch.touchMove(id, x, y)
  local n = native("touchMove")
  if n then return n(id, x, y) end
  return nyi("touchMove")
end
function touch.touchUp(id, x, y)
  local n = native("touchUp")
  if n then return n(id, x, y) end
  return nyi("touchUp")
end
function touch.swipe(x1, y1, x2, y2, ms)
  local n = native("swipe")
  if n then return n(x1, y1, x2, y2, ms) end
  return nyi("swipe")
end
function touch.longTap(x, y, ms)
  local n = native("longTap")
  if n then return n(x, y, ms) end
  local d, u = native("touchDown"), native("touchUp")
  if d and u then
    d(1, x, y)
    time_m_mSleep(tonumber(ms) or 800)
    u(1, x, y)
    return true
  end
  return nyi("longTap")
end

local screen = {}
function screen.keepScreen(on)
  local n = native("keepScreen")
  if n then return n(on) end
  return nyi("keepScreen")
end
function screen.snapshot(path)
  local n = native("snapshot")
  if n then return n(path) end
  return nyi("snapshot")
end
function screen.getScreenScale()
  if type(_G.ZiYanOrient) == "table" and type(_G.ZiYanOrient.logical_size) == "function" then
    local w, h = _G.ZiYanOrient.logical_size()
    return w, h
  end
  return 0, 0
end
function screen.getScreenSize()
  return screen.getScreenScale()
end
function screen.init(orient)
  local n = native("init")
  if n then return n(orient) end
  return nyi("init")
end
function screen.resetScreen(...)
  if type(_G.ZiYanOrient) == "table" and type(_G.ZiYanOrient.soft_sync) == "function" then
    return _G.ZiYanOrient.soft_sync()
  end
  return true, "ios_noop"
end

local time_m = {}
function time_m.mSleep(ms)
  return time_m_mSleep(ms)
end
function time_m.sleep(sec)
  return time_m_mSleep((tonumber(sec) or 0) * 1000)
end

local input = {}
function input.inputText(text)
  if type(_G.Zy) == "table" and _G.Zy.Input and type(_G.Zy.Input.text) == "function" then
    return _G.Zy.Input.text(text)
  end
  local n = native("inputText")
  if n then return n(text) end
  local w = native("writePasteboard")
  if w then w(tostring(text or "")) end
  return true, "pasteboard_fallback"
end
function input.inputStr(text)
  return input.inputText(text)
end
function input.inputKey(k)
  local n = native("inputKey")
  if n then return n(k) end
  return nyi("inputKey")
end
function input.keyDown(k)
  local n = native("keyDown")
  if n then return n(k) end
  return nyi("keyDown")
end
function input.keyUp(k)
  local n = native("keyUp")
  if n then return n(k) end
  return nyi("keyUp")
end
function input.writePasteboard(text)
  local n = native("writePasteboard")
  if n then return n(text) end
  return nyi("writePasteboard")
end
function input.readPasteboard()
  local n = native("readPasteboard")
  if n then return n() end
  return ""
end
function input.clipText()
  return input.readPasteboard()
end
function input.copyText(text)
  return input.writePasteboard(text)
end
function input.getInPutMethod()
  return "", "ios_unknown"
end

function input.clearPasteboard()
  return input.writePasteboard("")
end

function input.switchInputText()
  if type(_G.Zy) == "table" and _G.Zy.Input and type(_G.Zy.Input.switchInputText) == "function" then
    return _G.Zy.Input.switchInputText()
  end
  return false, "ios_no_ziyan_ime"
end

local keycode = {}
function keycode.home(...)
  -- 禁止走 Zy.Input.Keycode.home：其内部再调 pressHomeKey，compat 包装后会递归
  local n = native("pressHomeKey")
  if n then return n(1) end
  return input.keyDown("HOME")
end
function keycode.back(...)
  return false, "unsupported_on_ios"
end
function keycode.power(...)
  local n = native("keyDown")
  if n then
    n("POWER")
    local u = native("keyUp")
    if u then u("POWER") end
    return true, "keyDownUp"
  end
  return nyi("keycode.power")
end
function keycode.notification()
  return nyi("keycode.notification")
end
function keycode.quickSetting()
  return nyi("keycode.quickSetting")
end
function keycode.recent()
  return nyi("keycode.recent")
end
function keycode.splitScreen()
  return nyi("keycode.splitScreen")
end

local app = {}
function app.runApp(bid)
  local __n_runApp = native("runApp"); if __n_runApp then return __n_runApp(bid) end
  local __n_appRun = native("appRun"); if __n_appRun then return __n_appRun(bid) end
  return nyi("runApp")
end
function app.closeApp(bid)
  local __n_closeApp = native("closeApp"); if __n_closeApp then return __n_closeApp(bid) end
  return nyi("closeApp")
end
function app.frontAppBid()
  local __n_frontAppBid = native("frontAppBid"); if __n_frontAppBid then return __n_frontAppBid() end
  return ""
end
function app.isAppInstalled(bid)
  local __n_isAppInstalled = native("isAppInstalled"); if __n_isAppInstalled then return __n_isAppInstalled(bid) end
  return nyi("isAppInstalled")
end
function app.appIsRunning(bid)
  local __n_appIsRunning = native("appIsRunning"); if __n_appIsRunning then return __n_appIsRunning(bid) end
  return false
end

function app.appBundlePath(bid)
  if type(_G.Zy) == "table" and _G.Zy.App and type(_G.Zy.App.bundlePath) == "function" then
    return _G.Zy.App.bundlePath(bid)
  end
  return nil, "not_found"
end

function app.appDataPath(bid)
  if type(_G.Zy) == "table" and _G.Zy.App and type(_G.Zy.App.dataPath) == "function" then
    return _G.Zy.App.dataPath(bid)
  end
  return nil, "not_found"
end

local file = {}
function file.userPath()
  local __n_userPath = native("userPath"); if __n_userPath then return __n_userPath() end
  return "/private/var/mobile/Media/ZiYan"
end
function file.getList(dir)
  local __n_getList = native("getList"); if __n_getList then return __n_getList(dir) end
  return {}
end
function file.readFile(path)
  local __n_readFile = native("readFile"); if __n_readFile then return __n_readFile(path) end
  local f = io.open(tostring(path or ""), "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
function file.writeFile(path, data)
  local __n_writeFile = native("writeFile"); if __n_writeFile then return __n_writeFile(path, data) end
  local f = io.open(tostring(path or ""), "w")
  if not f then return false end
  f:write(tostring(data or "")); f:close(); return true
end
function file.delFile(path)
  local __n_delFile = native("delFile"); if __n_delFile then return __n_delFile(path) end
  if type(os) == "table" and type(os.remove) == "function" then return os.remove(path) end
  return false
end
function file.isFileExist(path)
  local __n_isFileExist = native("isFileExist"); if __n_isFileExist then return __n_isFileExist(path) end
  local f = io.open(tostring(path or ""), "r")
  if f then f:close(); return true end
  return false
end
function file.mkdir(path)
  if type(_G.Zy) == "table" and _G.Zy.File and type(_G.Zy.File.mkdir) == "function" then
    return _G.Zy.File.mkdir(path)
  end
  local __n_mkdir = native("mkdir")
  if __n_mkdir then return __n_mkdir(path) end
  path = tostring(path or "")
  if path == "" then return false end
  return os.execute(string.format('mkdir -p "%s"', path:gsub('"', ""))) == 0
end

function file.readFileString(path)
  return file.readFile(path) or ""
end

function file.writeFileString(path, data)
  return file.writeFile(path, data)
end

function file.copyfile(src, dst)
  if type(_G.Zy) == "table" and _G.Zy.File and type(_G.Zy.File.copy) == "function" then
    return _G.Zy.File.copy(src, dst)
  end
  if defined("FileCopy") then return FileCopy(src, dst) end
  src, dst = tostring(src or ""), tostring(dst or "")
  if src == "" or dst == "" then return false end
  return os.execute(string.format('cp -R "%s" "%s"', src:gsub('"', ""), dst:gsub('"', ""))) == 0
end

function file.movefile(src, dst)
  if type(_G.Zy) == "table" and _G.Zy.File and type(_G.Zy.File.move) == "function" then
    return _G.Zy.File.move(src, dst)
  end
  if defined("FileMove") then return FileMove(src, dst) end
  src, dst = tostring(src or ""), tostring(dst or "")
  if src == "" or dst == "" then return false end
  return os.execute(string.format('mv "%s" "%s"', src:gsub('"', ""), dst:gsub('"', ""))) == 0
end

function file.getFileSize(path)
  if type(_G.Zy) == "table" and _G.Zy.File and type(_G.Zy.File.size) == "function" then
    return _G.Zy.File.size(path)
  end
  path = tostring(path or "")
  local p = io.popen(string.format('stat -f%%z "%s" 2>/dev/null || stat -c%%s "%s" 2>/dev/null', path:gsub('"', ""), path:gsub('"', "")))
  if not p then return -1 end
  local s = tonumber(p:read("*l") or "-1") or -1
  p:close()
  return s
end

function file.getFile(path)
  return file.readFile(path) or ""
end

function file.loadFile(path)
  return file.getFile(path)
end

function file.rmFile(path)
  return file.delFile(path)
end

function file.getFileList(dir)
  return file.getList(dir)
end

function file.findFile(nameOrPattern, rootDir)
  if type(_G.Zy) == "table" and _G.Zy.File and type(_G.Zy.File.find) == "function" then
    return _G.Zy.File.find(nameOrPattern, rootDir)
  end
  return {}
end

--- 本地路径复制（非 TS 云盘）
function file.pull_file(src, dst)
  return file.copyfile(src, dst)
end

function file.push_file(src, dst)
  return file.copyfile(src, dst)
end

function file.zip(src, dst)
  src, dst = tostring(src or ""), tostring(dst or "")
  if src == "" or dst == "" then return false, "empty_path" end
  if type(_G.Zy) == "table" and _G.Zy.File and type(_G.Zy.File.zip) == "function" then
    return _G.Zy.File.zip(src, dst)
  end
  local cmd = string.format('zip -r -q "%s" "%s" >/dev/null 2>&1; echo $?', dst:gsub('"', ""), src:gsub('"', ""))
  local p = io.popen(cmd)
  if not p then return false end
  local code = p:read("*l") or "1"
  p:close()
  return tostring(code):match("^0") ~= nil
end

function file.unzip(src, dst)
  src, dst = tostring(src or ""), tostring(dst or "")
  if src == "" then return false, "empty_path" end
  if type(_G.Zy) == "table" and _G.Zy.File and type(_G.Zy.File.unzip) == "function" then
    return _G.Zy.File.unzip(src, dst)
  end
  dst = dst ~= "" and dst or "."
  local cmd = string.format('unzip -o -q "%s" -d "%s" >/dev/null 2>&1; echo $?', src:gsub('"', ""), dst:gsub('"', ""))
  local p = io.popen(cmd)
  if not p then return false end
  local code = p:read("*l") or "1"
  p:close()
  return tostring(code):match("^0") ~= nil
end

local function cloud_unsupported()
  return unsupported("ts_cloud")
end

function file.cloud_file_del(...) return cloud_unsupported(...) end
function file.cloud_file_list(...) return cloud_unsupported(...) end
function file.cloud_file_load(...) return cloud_unsupported(...) end
function file.cloud_file_new(...) return cloud_unsupported(...) end
function file.cloud_file_pull(...) return cloud_unsupported(...) end
function file.cloud_file_push(...) return cloud_unsupported(...) end
function file.cloud_file_rename(...) return cloud_unsupported(...) end
function file.cloud_file_save(...) return cloud_unsupported(...) end
function file.remote_file_load(...) return cloud_unsupported(...) end
function file.remote_file_save(...) return cloud_unsupported(...) end

local log = {}
function log.toast(msg, ms)
  local __n_toast = native("toast"); if __n_toast then return __n_toast(msg, ms) end
end
function log.notifyMessage(msg, ms)
  local __n_notifyMessage = native("notifyMessage"); if __n_notifyMessage then return __n_notifyMessage(msg, ms) end
  return log.toast(msg, ms)
end
function log.sysLog(msg)
  local __n_sysLog = native("sysLog"); if __n_sysLog then return __n_sysLog(msg) end
  local __n_nLog = native("nLog"); if __n_nLog then return __n_nLog(msg) end
  print(tostring(msg))
end
function log.nLog(...)
  local __n_nLog = native("nLog"); if __n_nLog then return __n_nLog(...) end
  print(...)
end
function log.dialog(msg)
  return log.toast(msg, 2000)
end

function log.dialogRet(msg, btn1, btn2, timeout)
  if type(_G.Zy) == "table" and _G.Zy.Dialog and type(_G.Zy.Dialog.ret) == "function" then
    return _G.Zy.Dialog.ret(msg, btn1, btn2, timeout)
  end
  log.toast(tostring(msg), (tonumber(timeout) or 0) > 0 and timeout * 1000 or 2500)
  return 0, tostring(btn1 or "确定")
end

function log.dialogInput(title, default, timeout)
  if type(_G.Zy) == "table" and _G.Zy.Dialog and type(_G.Zy.Dialog.inputRet) == "function" then
    return _G.Zy.Dialog.inputRet(title, default, timeout)
  end
  log.toast(tostring(title), 2000)
  return false, tostring(default or ""), "no_modal_input"
end

local device = {}
function device.unlockDevice(pass)
  local __n_unlockDevice = native("unlockDevice"); if __n_unlockDevice then return __n_unlockDevice(pass) end
  return nyi("unlockDevice")
end
function device.deviceIsLock()
  local __n_deviceIsLock = native("deviceIsLock"); if __n_deviceIsLock then return __n_deviceIsLock() end
  return false
end
function device.getOSVer()
  local __n_getOSVer = native("getOSVer"); if __n_getOSVer then return __n_getOSVer() end
  return ""
end
function device.getVersion()
  if type(_G.ZIYAN_VERSION) == "string" and _G.ZIYAN_VERSION ~= "" then
    return _G.ZIYAN_VERSION
  end
  if type(_G.Zy) == "table" and type(_G.Zy.version) == "string" then
    return _G.Zy.version
  end
  return M.version
end
function device.getDeviceType()
  local __n_getDeviceType = native("getDeviceType"); if __n_getDeviceType then return __n_getDeviceType() end
  return "iPhone"
end
function device.getScreenScale()
  return screen.getScreenScale()
end
function device.getNetTime()
  return os.time()
end
function device.getNetIP()
  if type(_G.Zy) == "table" and _G.Zy.Network and type(_G.Zy.Network.netIP) == "function" then
    return _G.Zy.Network.netIP()
  end
  local __n_getNetIP = native("getNetIP"); if __n_getNetIP then return __n_getNetIP() end
  return ""
end

function device.batteryStatus()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.batteryLevel) == "function" then
    return _G.Zy.Device.batteryLevel()
  end
  local p = io.popen("ioreg -l 2>/dev/null | grep -i BatteryCurrentCapacity | head -1")
  if p then
    local s = p:read("*l") or ""
    p:close()
    local n = s:match("(%d+)")
    if n then return tonumber(n) end
  end
  return -1
end

function device.getBatteryLevel()
  return device.batteryStatus()
end

--- Division2 Wave3 · Device
function device.getOSType()
  return "iOS"
end

function device.getDeviceID()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.deviceId) == "function" then
    return _G.Zy.Device.deviceId()
  end
  local p = io.popen("ioreg -d2 -c IOPlatformExpertDevice 2>/dev/null | awk -F\\\" '/IOPlatformUUID/{print $(NF-1); exit}'")
  if p then
    local s = (p:read("*l") or ""):gsub("%s+$", "")
    p:close()
    if #s > 0 then return s end
  end
  return device.getDeviceType()
end

function device.deviceid()
  return device.getDeviceID()
end

function device.getDeviceName()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.deviceName) == "function" then
    return _G.Zy.Device.deviceName()
  end
  local p = io.popen("scutil --get ComputerName 2>/dev/null || hostname")
  if p then
    local s = (p:read("*l") or ""):gsub("%s+$", "")
    p:close()
    if #s > 0 then return s end
  end
  return "iPhone"
end

function device.devicename()
  return device.getDeviceName()
end

function device.getDeviceAlias()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.getAlias) == "function" then
    return _G.Zy.Device.getAlias()
  end
  return device.getDeviceName()
end

function device.setDeviceAlias(name)
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.setAlias) == "function" then
    return _G.Zy.Device.setAlias(name)
  end
  return false, "no_device_module"
end

function device.setDeviceName(name)
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.setDeviceName) == "function" then
    return _G.Zy.Device.setDeviceName(name)
  end
  return device.setDeviceAlias(name)
end

function device.getMemoryInfo()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.memoryInfo) == "function" then
    return _G.Zy.Device.memoryInfo()
  end
  return { total = 0, free = 0, used = 0 }
end

function device.getNetInterfaces()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.netInterfaces) == "function" then
    return _G.Zy.Device.netInterfaces()
  end
  return {}
end

function device.deviceIsAuth()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.isAuth) == "function" then
    return _G.Zy.Device.isAuth() and 1 or 0
  end
  return 1
end

function device.lockDevice()
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.lock) == "function" then
    return _G.Zy.Device.lock()
  end
  local var = (type(_G.ZIYAN_VAR) == "string" and _G.ZIYAN_VAR) or "/usr/lib/ziyan/var"
  local f = io.open(var .. "/.ziyan_lock_req", "w")
  if f then f:write("1\n"); f:close(); return true end
  return false, "write_lock_req_failed"
end

function device.setWifiEnable(on)
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.setWifiEnable) == "function" then
    return _G.Zy.Device.setWifiEnable(on)
  end
  return false, "no_device_module"
end

function device.connectToWifi(ssid, password)
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.connectToWifi) == "function" then
    return _G.Zy.Device.connectToWifi(ssid, password)
  end
  return false, "no_device_module"
end

function device.setAutoLockTime(sec)
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.setAutoLockTime) == "function" then
    return _G.Zy.Device.setAutoLockTime(sec)
  end
  return false, "no_device_module"
end

function device.setRotationLockEnable(on)
  if type(_G.Zy) == "table" and _G.Zy.Device and type(_G.Zy.Device.setRotationLockEnable) == "function" then
    return _G.Zy.Device.setRotationLockEnable(on)
  end
  return false, "no_device_module"
end

function device.getBrightness()
  return nyi("getBrightness")
end

function device.setBrightness(...)
  return nyi("setBrightness")
end

function device.vibrate(...)
  return nyi("vibrate")
end

function device.playAudio(...)
  return nyi("playAudio")
end

function device.openURL(url)
  local __n_openURL = native("openURL"); if __n_openURL then return __n_openURL(url) end
  return nyi("openURL")
end

local util = {}
function util.getRndNum(a, b)
  a, b = tonumber(a) or 0, tonumber(b) or 1
  if b < a then a, b = b, a end
  return math.random(a, b)
end

function util.urlEncode(s)
  s = tostring(s or "")
  return (s:gsub("([^%w%-_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function util.urlDecode(s)
  s = tostring(s or ""):gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

function util.split(str, sep)
  str, sep = tostring(str or ""), tostring(sep or ",")
  local t = {}
  for part in string.gmatch(str, "([^" .. sep .. "]+)") do
    t[#t + 1] = part
  end
  return t
end

function util.strSplit(str, sep)
  return util.split(str, sep)
end

function util.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.ltrim(s)
  return (tostring(s or ""):gsub("^%s+", ""))
end

function util.rtrim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end

function util.atrim(s)
  return util.trim(s)
end

function util.getRndStr(len, charset)
  len = tonumber(len) or 8
  charset = tostring(charset or "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  if #charset < 1 then charset = "abc" end
  local out = {}
  for i = 1, len do
    local idx = math.random(1, #charset)
    out[i] = charset:sub(idx, idx)
  end
  return table.concat(out)
end

function util.getStrNum(s)
  s = tostring(s or "")
  local n = 0
  for _ in s:gmatch("%d") do n = n + 1 end
  return n
end

local function shell_out(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local s = p:read("*a") or ""
  p:close()
  return s
end

function util.base64Encode(s)
  s = tostring(s or "")
  local tmp = (_G.ZIYAN_VAR or "/usr/lib/ziyan/var") .. "/.zy_b64_in"
  local out = (_G.ZIYAN_VAR or "/usr/lib/ziyan/var") .. "/.zy_b64_out"
  local f = io.open(tmp, "wb")
  if f then f:write(s); f:close() end
  shell_out(string.format("base64 '%s' > '%s'", tmp:gsub("'", ""), out:gsub("'", "")))
  local rf = io.open(out, "rb")
  if not rf then return nyi("base64Encode") end
  local b = (rf:read("*a") or ""):gsub("%s+$", "")
  rf:close()
  return b
end

function util.base64Decode(s)
  s = tostring(s or ""):gsub("%s+", "")
  local tmp = (_G.ZIYAN_VAR or "/usr/lib/ziyan/var") .. "/.zy_b64_dec_in"
  local out = (_G.ZIYAN_VAR or "/usr/lib/ziyan/var") .. "/.zy_b64_dec_out"
  local f = io.open(tmp, "w")
  if f then f:write(s); f:close() end
  shell_out(string.format("base64 -D -i '%s' > '%s' 2>/dev/null || base64 -d '%s' > '%s'",
    tmp:gsub("'", ""), out:gsub("'", ""), tmp:gsub("'", ""), out:gsub("'", "")))
  local rf = io.open(out, "rb")
  if not rf then return nyi("base64Decode") end
  local b = rf:read("*a") or ""
  rf:close()
  return b
end

function util.md5(s)
  s = tostring(s or "")
  local h = shell_out(string.format("echo -n '%s' | md5 2>/dev/null || md5 -q -s '%s'",
    s:gsub("'", ""), s:gsub("'", "")))
  return (h:gsub("%s+$", ""))
end

function util.jsonEncode(t)
  local ok, json = pcall(require, "json")
  if not ok then
    local root = (_G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua") .. "/json.lua"
    ok, json = pcall(dofile, root)
  end
  if ok and type(json) == "table" and type(json.encode) == "function" then
    return json.encode(t)
  end
  return nyi("jsonEncode")
end

function util.jsonDecode(s)
  local ok, json = pcall(require, "json")
  if not ok then
    local root = (_G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua") .. "/json.lua"
    ok, json = pcall(dofile, root)
  end
  if ok and type(json) == "table" and type(json.decode) == "function" then
    return json.decode(tostring(s or ""))
  end
  return nyi("jsonDecode")
end

function util.isJSON(s)
  s = tostring(s or "")
  if s == "" then return false end
  local ok, val = pcall(util.jsonDecode, s)
  return ok and val ~= nil
end

--- JSON / json 模块表（TS 风格 callable）
util.JSON = {
  encode = function(t) return util.jsonEncode(t) end,
  decode = function(s) return util.jsonDecode(s) end,
}
util.json = util.JSON

function util.JSON_callable()
  return util.JSON
end

local net = {}
net._timeout = 8
net._ftp_timeout = 30

function net.setTimeout(sec)
  net._timeout = math.max(1, tonumber(sec) or 8)
  if type(_G.Zy) == "table" and _G.Zy.Network and type(_G.Zy.Network.setTimeout) == "function" then
    _G.Zy.Network.setTimeout(net._timeout)
  end
  return net._timeout
end

function net.httpBuildQuery(tbl)
  if type(_G.Zy) == "table" and _G.Zy.Network and type(_G.Zy.Network.httpBuildQuery) == "function" then
    return _G.Zy.Network.httpBuildQuery(tbl)
  end
  if type(tbl) ~= "table" then return "" end
  local parts = {}
  for k, v in pairs(tbl) do
    parts[#parts + 1] = string.format("%s=%s", util.urlEncode(tostring(k)), util.urlEncode(tostring(v)))
  end
  return table.concat(parts, "&")
end

function net.httpGet(url, timeout)
  timeout = tonumber(timeout) or net._timeout
  if type(_G.Zy) == "table" and _G.Zy.Network and type(_G.Zy.Network.httpGet) == "function" then
    local ok, res = _G.Zy.Network.httpGet(url, timeout)
    if ok then return res end
    return ""
  end
  if defined("httpGet") then return httpGet(url, timeout) or "" end
  return ""
end

function net.httpPost(url, body, timeout, headers)
  timeout = tonumber(timeout) or net._timeout
  if type(_G.Zy) == "table" and _G.Zy.Network and type(_G.Zy.Network.httpPost) == "function" then
    local ok, res = _G.Zy.Network.httpPost(url, body, timeout, headers)
    if ok then return res end
    return ""
  end
  return nyi("httpPost")
end

function net.HTTP()
  return {
    get = net.httpGet,
    post = net.httpPost,
    setTimeout = net.setTimeout,
    buildQuery = net.httpBuildQuery,
  }
end

local ftp = {}
ftp._timeout = 30

function ftp.setTimeout(sec)
  ftp._timeout = math.max(1, tonumber(sec) or 30)
  net._ftp_timeout = ftp._timeout
  return ftp._timeout
end

local function ftp_wrap(fn, ...)
  if type(fn) == "function" then
    return fn(...)
  end
  return { ok = false, error = "no_ftp_backend" }
end

function ftp.upload(host, user, password, local_path, remote_path, port)
  return ftp_wrap(_G.FtpUpload or _G.ftp_upload, host, user, password, local_path, remote_path, port, ftp._timeout)
end

function ftp.download(host, user, password, remote_path, local_path, port)
  return ftp_wrap(_G.FtpDownload or _G.ftp_download, host, user, password, remote_path, local_path, port, ftp._timeout)
end

function ftp.delete(host, user, password, remote_path, port)
  return ftp_wrap(_G.FtpDelete or _G.ftp_delete, host, user, password, remote_path, port, ftp._timeout)
end

function ftp.read(host, user, password, remote_path, port)
  return ftp_wrap(_G.FtpRead or _G.ftp_read, host, user, password, remote_path, port, ftp._timeout)
end

local function ftp_cfg_args(host, user, password, port)
  if host == nil and ftp._cfg then
    return ftp._cfg.host, ftp._cfg.user, ftp._cfg.password, ftp._cfg.port
  end
  return host, user, password, port or (ftp._cfg and ftp._cfg.port) or 21
end

local function ftp_curl_q(host, user, password, port, quote, path)
  host, user, password, port = ftp_cfg_args(host, user, password, port)
  port = tonumber(port) or 21
  path = tostring(path or "")
  local url = string.format("ftp://%s:%d/%s", tostring(host or ""), port, path)
  local cmd = string.format(
    "curl -s --max-time %d --user '%s:%s' -Q '%s' '%s' 2>/dev/null",
    ftp._timeout or 30,
    tostring(user or ""):gsub("'", ""),
    tostring(password or ""):gsub("'", ""),
    tostring(quote or ""):gsub("'", ""),
    url:gsub("'", ""))
  local p = io.popen(cmd)
  if not p then return false, "" end
  local body = p:read("*a") or ""
  local ok = p:close()
  return ok ~= nil, body
end

function ftp.init(host, user, password, port)
  ftp._cfg = {
    host = tostring(host or ""),
    user = tostring(user or ""),
    password = tostring(password or ""),
    port = tonumber(port) or 21,
  }
  return true
end

function ftp.clean()
  ftp._cfg = nil
  return true
end

function ftp.list(host, user, password, remote_path, port)
  host, user, password, port = ftp_cfg_args(host, user, password, port)
  port = tonumber(port) or 21
  remote_path = tostring(remote_path or "")
  local url = string.format("ftp://%s:%d/%s", tostring(host or ""), port, remote_path)
  local cmd = string.format(
    "curl -s --list-only --max-time %d --user '%s:%s' '%s' 2>/dev/null",
    ftp._timeout or 30,
    tostring(user or ""):gsub("'", ""),
    tostring(password or ""):gsub("'", ""),
    url:gsub("'", ""))
  local p = io.popen(cmd)
  if not p then return {} end
  local t = {}
  for line in p:lines() do
    if line ~= "" then t[#t + 1] = line end
  end
  p:close()
  return t
end

function ftp.mkdir(host, user, password, dirname, port)
  if ftp._cfg and (user == nil or type(user) ~= "string" or #tostring(password or "") == 0 and dirname == nil) then
    -- ftp.mkdir("dir") after init
    dirname = host
    host, user, password, port = ftp_cfg_args(nil, nil, nil, nil)
  end
  local ok = ftp_curl_q(host, user, password, port, "MKD " .. tostring(dirname or ""), "")
  return ok and true or false
end

function ftp.rmdir(host, user, password, dirname, port)
  if ftp._cfg and dirname == nil then
    dirname = host
    host, user, password, port = ftp_cfg_args(nil, nil, nil, nil)
  end
  local ok = ftp_curl_q(host, user, password, port, "RMD " .. tostring(dirname or ""), "")
  return ok and true or false
end

function ftp.rename(host, user, password, from_name, to_name, port)
  if ftp._cfg and to_name == nil then
    -- ftp.rename(from, to)
    to_name = user
    from_name = host
    host, user, password, port = ftp_cfg_args(nil, nil, nil, nil)
  end
  host, user, password, port = ftp_cfg_args(host, user, password, port)
  port = tonumber(port) or 21
  local cmd = string.format(
    "curl -s --max-time %d --user '%s:%s' -Q 'RNFR %s' -Q 'RNTO %s' 'ftp://%s:%d/' >/dev/null 2>&1; echo $?",
    ftp._timeout or 30,
    tostring(user or ""):gsub("'", ""),
    tostring(password or ""):gsub("'", ""),
    tostring(from_name or ""):gsub("'", ""),
    tostring(to_name or ""):gsub("'", ""),
    tostring(host or ""), port)
  local p = io.popen(cmd)
  if not p then return false end
  local code = p:read("*l") or "1"
  p:close()
  return tostring(code):match("^0") ~= nil
end

function net.FTP()
  return ftp
end

----------------------------------------------------------------------
-- Wave4 thread / widget
----------------------------------------------------------------------
local thread = {}
function thread.create(...)
  if type(_G.Zy) == "table" and _G.Zy.Thread then return _G.Zy.Thread.create(...) end
  return nyi("thread.create")
end
function thread.createSubThread(...)
  if type(_G.Zy) == "table" and _G.Zy.Thread then return _G.Zy.Thread.createSubThread(...) end
  return thread.create(...)
end
function thread.wait(...)
  if type(_G.Zy) == "table" and _G.Zy.Thread then return _G.Zy.Thread.wait(...) end
  local ms = tonumber((...)) or 0
  if type(_G.mSleep) == "function" then mSleep(ms); return true end
  return nyi("thread.wait")
end
function thread.setTimeout(...)
  if type(_G.Zy) == "table" and _G.Zy.Thread then return _G.Zy.Thread.setTimeout(...) end
  return nyi("thread.setTimeout")
end
function thread.clearTimeout(...)
  if type(_G.Zy) == "table" and _G.Zy.Thread then return _G.Zy.Thread.clearTimeout(...) end
  return false
end
function thread.stop(...)
  if type(_G.Zy) == "table" and _G.Zy.Thread then return _G.Zy.Thread.stop(...) end
  return false
end
function thread.waitAllThreadExit(...)
  if type(_G.Zy) == "table" and _G.Zy.Thread then return _G.Zy.Thread.waitAllThreadExit(...) end
  return true
end

local widget = {}
function widget.isAccessibilityOn()
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.isAccessibilityOn() end
  return false
end
function widget.find(...)
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.find(...) end
  return false
end
function widget.click(...)
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.click(...) end
  return false, "no_widget"
end
function widget.longClick(...)
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.longClick(...) end
  return false, "no_widget"
end
function widget.region(...)
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.region(...) end
  return true
end
function widget.scrollForward(...)
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.scrollForward(...) end
  return false
end
function widget.scrollBackward(...)
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.scrollBackward(...) end
  return false
end
function widget.setText(...)
  if type(_G.Zy) == "table" and _G.Zy.Widget then return _G.Zy.Widget.setText(...) end
  return false
end

-- global aliases used by mirror (isAccessibilityOn is top-level)
function device.getNetworkIP()
  return device.getNetIP()
end

local script = {}
function script.lua_exit()
  local __n_lua_exit = native("lua_exit"); if __n_lua_exit then return __n_lua_exit() end
  os.exit(0)
end

local image = {}
function image.findImage(...)
  local __n_findImage = native("findImage"); if __n_findImage then return __n_findImage(...) end
  return -1, -1
end

local ocr = {}
function ocr.ocrText(...)
  if type(_G.Zy) == "table" and _G.Zy.OCR and type(_G.Zy.OCR.recognize) == "function" then
    return _G.Zy.OCR.recognize(...)
  end
  return ""
end

local stub = {}
function stub.planned(...)
  return nyi("planned")
end
function stub.unsupported(...)
  return unsupported("ts_private_or_cloud")
end
function stub.generic(...)
  return nyi("generic")
end

--- HTTP/FTP/JSON 全局 callable 模块表
function stub.HTTP_module()
  return net.HTTP()
end

function stub.FTP_module()
  return net.FTP()
end

function stub.JSON_module()
  return util.JSON
end

local NS = {
  color = color,
  touch = touch,
  screen = screen,
  time = time_m,
  input = input,
  keycode = keycode,
  app = app,
  file = file,
  log = log,
  device = device,
  util = util,
  net = net,
  ftp = ftp,
  thread = thread,
  widget = widget,
  script = script,
  image = image,
  ocr = ocr,
  stub = stub,
}

--- key like "color.getColor" or "stub.generic:file"
function M.call(key, ...)
  key = tostring(key or "")
  if key:sub(1, 13) == "stub.generic:" then
    return stub.generic(key)
  end
  if key:sub(1, 18) == "stub.unsupported:" then
    return unsupported(key:sub(19))
  end
  if key == "stub.HTTP_module" then return stub.HTTP_module() end
  if key == "stub.FTP_module" then return stub.FTP_module() end
  if key == "stub.JSON_module" then return stub.JSON_module() end
  local a, b = key:match("^([%w_]+)%.([%w_]+)$")
  if not a then
    return nyi(key)
  end
  local mod = NS[a]
  if not mod then return nyi(key) end
  local fn = mod[b]
  if type(fn) ~= "function" then return nyi(key) end
  return fn(...)
end

M.NS = NS
return M
