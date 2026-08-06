--[[ Zy.Device — 设备模型模块（函数模块层）
  子砚自研 API；不调用 TouchSprite。
  Division2 Wave3：内存/网卡/设备名/别名/WiFi·锁屏请求（SB 侧消费）
]]
local C = require("modules._ctx")
local M = { name = "Device", version = "1.2.0" }

local function defined(n) return type(_G[n]) == "function" end

local function shell_one(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local s = p:read("*l") or ""
  p:close()
  return (s:gsub("%s+$", ""))
end

local function shell_all(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local s = p:read("*a") or ""
  p:close()
  return s
end

local function resolve_var()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var/.gitkeep", "r")
      or io.open("/var/jb/usr/lib/ziyan/lib/lua/ziyan_engine/init.lua", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function write_var(name, body)
  local path = resolve_var() .. "/" .. name
  local f = io.open(path, "w")
  if not f then return false end
  f:write(tostring(body or ""))
  f:close()
  return true
end

local function read_var(name)
  local f = io.open(resolve_var() .. "/" .. name, "r")
  if not f then return nil end
  local s = f:read("*a") or ""
  f:close()
  return s
end

function M.refresh()
  if defined("deviceRefresh") then
    pcall(deviceRefresh)
  elseif defined("deviceModel") then
    pcall(deviceModel)
  end
  C.mark_device()
  return M.profile()
end

function M.profile()
  if defined("deviceModel") then return deviceModel() end
  if defined("deviceProfile") then return deviceProfile() end
  return _G.__ZIYAN_DEVICE_PROFILE
end

function M.save()
  if defined("deviceSaveProfile") then return deviceSaveProfile() end
  return false, "no_device_save"
end

function M.gameRect()
  if defined("deviceGameRect") then return deviceGameRect() end
  local p = M.profile() or {}
  local g = p.game_rect or {}
  return g.x or 0, g.y or 0, g.w or 0, g.h or 0
end

function M.unlock()
  if defined("deviceUnlock") then return deviceUnlock() end
  if defined("unlockDevice") then return unlockDevice() end
  return false
end

--- 是否锁屏：1=锁 0=未锁（对齐 deviceIsLock）
function M.isLocked()
  if defined("deviceIsLock") then
    return (tonumber(deviceIsLock()) or 0) ~= 0
  end
  return false
end

--- 系统版本字符串
function M.osVersion()
  if defined("getOSVer") then return tostring(getOSVer() or "") end
  local p = M.profile() or {}
  return tostring(p.os or "")
end

--- 电量 0–100；读不到返回 -1
function M.batteryLevel()
  if defined("batteryStatus") then
    local v = batteryStatus()
    if type(v) == "number" then return v end
    if type(v) == "string" then
      local n = tonumber(v:match("(%d+)"))
      if n then return n end
    end
  end
  if defined("getBatteryLevel") then
    local v = getBatteryLevel()
    if tonumber(v) then return tonumber(v) end
  end
  local s = shell_one("ioreg -l | grep -i BatteryCurrentCapacity | head -1")
  local n = s and s:match("(%d+)")
  if n then return tonumber(n) end
  return -1
end

--- 局域网 IP
function M.ip()
  if type(_G.Zy) == "table" and _G.Zy.Network and type(_G.Zy.Network.netIP) == "function" then
    return _G.Zy.Network.netIP()
  end
  if defined("getNetIP") then return getNetIP() or "" end
  return ""
end

--- Wave3：系统类型
function M.osType()
  return "iOS"
end

--- Wave3：设备 ID（UDID 优先）
function M.deviceId()
  local id = shell_one("ioreg -d2 -c IOPlatformExpertDevice | awk -F\\\" '/IOPlatformUUID/{print $(NF-1); exit}'")
  if id == "" then
    id = shell_one("sysctl -n kern.uuid")
  end
  if id == "" then
    id = shell_one("uname -n")
  end
  return id
end

--- Wave3：设备名
function M.deviceName()
  local n = shell_one("scutil --get ComputerName")
  if n == "" then n = shell_one("hostname") end
  if n == "" then n = "iPhone" end
  return n
end

--- Wave3：别名（本地 var 持久化）
function M.getAlias()
  local s = read_var(".ziyan_device_alias")
  if s and #s > 0 then
    return (s:gsub("%s+$", ""))
  end
  return M.deviceName()
end

function M.setAlias(name)
  name = tostring(name or "")
  if #name < 1 then return false, "empty_alias" end
  return write_var(".ziyan_device_alias", name .. "\n"), nil
end

function M.setDeviceName(name)
  name = tostring(name or "")
  if #name < 1 then return false, "empty_name" end
  os.execute(string.format("scutil --set ComputerName %q 2>/dev/null", name))
  os.execute(string.format("scutil --set HostName %q 2>/dev/null", name))
  os.execute(string.format("scutil --set LocalHostName %q 2>/dev/null", name:gsub("[^%w%-]", "")))
  M.setAlias(name)
  return true
end

--- Wave3：内存信息 total/free/used 字节
function M.memoryInfo()
  local total = tonumber(shell_one("sysctl -n hw.memsize")) or 0
  local free = 0
  local vm = shell_all("vm_stat")
  local page = tonumber(vm:match("page size of (%d+)")) or 16384
  local free_pages = tonumber(vm:match("Pages free:%s+(%d+)")) or 0
  local speculative = tonumber(vm:match("Pages speculative:%s+(%d+)")) or 0
  free = (free_pages + speculative) * page
  return {
    total = total,
    free = free,
    used = math.max(0, total - free),
  }
end

--- Wave3：网卡列表
function M.netInterfaces()
  local out = {}
  local raw = shell_all("ifconfig -a 2>/dev/null || ifconfig")
  local cur = nil
  for line in string.gmatch(raw .. "\n", "([^\n]*)\n") do
    local iface = line:match("^([%w%.:%-]+):")
    if iface then
      cur = iface
      out[cur] = out[cur] or { name = cur, ip = "" }
    elseif cur then
      local ip = line:match("inet (%d+%.%d+%.%d+%.%d+)")
      if ip and out[cur].ip == "" then
        out[cur].ip = ip
      end
    end
  end
  local list = {}
  for _, v in pairs(out) do
    list[#list + 1] = v
  end
  table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return list
end

--- Wave3：越狱环境视为已授权
function M.isAuth()
  return true
end

--- Wave3：锁屏请求（SB pollDeviceControl）
function M.lock()
  write_var(".ziyan_lock_req", "1\n")
  return true
end

function M.setWifiEnable(on)
  local v = (on == true or on == 1 or on == "1" or on == "true") and "1" or "0"
  write_var(".ziyan_wifi_enable_req", v .. "\n")
  return true
end

function M.connectToWifi(ssid, password)
  ssid = tostring(ssid or "")
  if #ssid < 1 then return false, "empty_ssid" end
  local body = string.format("ssid=%s\npass=%s\n", ssid, tostring(password or ""))
  write_var(".ziyan_wifi_connect_req", body)
  return true, "req_written"
end

function M.setAutoLockTime(sec)
  sec = tonumber(sec) or 0
  write_var(".ziyan_autolock_req", tostring(sec) .. "\n")
  return true
end

function M.setRotationLockEnable(on)
  local v = (on == true or on == 1 or on == "1" or on == "true") and "1" or "0"
  write_var(".ziyan_rotation_lock_req", v .. "\n")
  return true
end

--- Wave4：公网/网络 IP（别名 getNetworkIP）
function M.networkIP()
  return M.ip()
end

return M
