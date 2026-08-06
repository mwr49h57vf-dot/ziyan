--[[ Zy.Input — 文本输入 + 音量键监听（经子砚 SDK，不调用 TouchSprite）]]
local ok_c, C = pcall(require, "modules._ctx")
if not ok_c then
  C = { require_pipeline = function() end }
end
local M = { name = "Input", version = "1.2.0", model = "TextInputAndVolume" }

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

local function write_flag(name, body)
  local path = var_dir() .. "/" .. name
  local f = io.open(path, "w")
  if not f then return false, "open_fail" end
  f:write(body or "")
  f:close()
  return true, path
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- 输入字符串到当前焦点（优先引擎 inputText / inputStr）
function M.text(str, opts)
  C.require_pipeline("touch")
  str = tostring(str or "")
  opts = opts or {}
  if str == "" then return false, "empty" end
  if defined("inputText") then
    local ok = pcall(inputText, str)
    return ok and true or false, "inputText"
  end
  if defined("inputStr") then
    local ok = pcall(inputStr, str)
    return ok and true or false, "inputStr"
  end
  if defined("inputKey") and #str == 1 then
    local ok = pcall(inputKey, str)
    return ok and true or false, "inputKey"
  end
  return false, "no_input_api"
end

--- 切换输入法到子砚 iOS 输入法：无 TS 私有 IME，诚实失败
function M.switchInputText()
  return false, "ios_no_ziyan_ime"
end

--- 剪贴板写入/读取（Zy.Input 短路径）
function M.setClipboard(text)
  if type(_G.Zy) == "table" and _G.Zy.Clipboard then
    return _G.Zy.Clipboard.set(text)
  end
  if defined("writePasteboard") then return writePasteboard(tostring(text or "")) end
  return false, "no_pasteboard"
end

function M.getClipboard()
  if type(_G.Zy) == "table" and _G.Zy.Clipboard then
    return _G.Zy.Clipboard.get()
  end
  if defined("readPasteboard") then return readPasteboard() or "" end
  return ""
end

function M.clearClipboard()
  if type(_G.Zy) == "table" and _G.Zy.Clipboard then
    return _G.Zy.Clipboard.clear()
  end
  if defined("clearPasteboard") then return clearPasteboard() end
  return M.setClipboard("")
end

--- 顺序按键（keyDown/keyUp 链；无后端则 false）
function M.keySequence(keys, interval_ms)
  if type(keys) ~= "table" then return false, "need_table" end
  interval_ms = tonumber(interval_ms) or 40
  if not defined("keyDown") or not defined("keyUp") then
    return false, "no_key_backend"
  end
  for _, k in ipairs(keys) do
    pcall(keyDown, tostring(k))
    if defined("mSleep") then mSleep(interval_ms) end
    pcall(keyUp, tostring(k))
  end
  return true
end

--- 清空：连按删除（次数可控；无系统 clear 时的兜底）
function M.clear(times)
  times = tonumber(times) or 12
  if defined("keyDown") and defined("keyUp") then
    for _ = 1, times do
      pcall(keyDown, "Delete")
      if defined("mSleep") then mSleep(30) end
      pcall(keyUp, "Delete")
    end
    return true, "delete_keys"
  end
  return false, "no_clear"
end

--- 先点比例焦点再输入（常用登录框）
function M.typeAtRatio(rx, ry, str, wait_ms)
  local Zy = assert(_G.Zy, "Zy required")
  wait_ms = tonumber(wait_ms) or 400
  Zy.Touch.tapRatio(rx, ry)
  if defined("mSleep") then mSleep(wait_ms) end
  return M.text(str)
end

----------------------------------------------------------------------
-- Input.VolumeMonitor — 物理音量键监听 / 触发（对齐 TS 快捷控制思想）
----------------------------------------------------------------------
local VM = {
  name = "VolumeMonitor",
  version = "1.0.0",
  _onDown = nil,
  _onUp = nil,
  _poll_pos = 0,
  _running = false,
}

--- 确保音量−拦截开启（恢复运行信息窗口）
function VM.enable()
  return write_flag(".ziyan_active", "1\n")
end

--- 触发音量−：弹出子砚原有运行信息窗口（运行/暂停/停止）
function VM.VolumeDown()
  VM.enable()
  local ok = write_flag(".ziyan_vol_trig", "1\n")
  if type(VM._onDown) == "function" then
    pcall(VM._onDown, "VolumeDown")
  end
  return ok
end

--- 记录/模拟音量+ 事件（写事件日志；系统音量由 SB hook 处理）
function VM.VolumeUp()
  local path = var_dir() .. "/.ziyan_vol_event"
  local prev = read_file(path) or ""
  local f = io.open(path, "a")
  if f then
    f:write("event=VolumeUp\ntrig=lua_VolumeUp\n")
    f:close()
  end
  if type(VM._onUp) == "function" then
    pcall(VM._onUp, "VolumeUp")
  end
  return true, path
end

function VM.onVolumeDown(cb)
  VM._onDown = cb
  return true
end

function VM.onVolumeUp(cb)
  VM._onUp = cb
  return true
end

--- 轮询 .ziyan_vol_event，派发回调（脚本循环内调用）
function VM.poll()
  local path = var_dir() .. "/.ziyan_vol_event"
  local body = read_file(path) or ""
  if #body <= VM._poll_pos then
    return false
  end
  local chunk = body:sub(VM._poll_pos + 1)
  VM._poll_pos = #body
  local hit = false
  if chunk:find("event=VolumeDown", 1, true) or chunk:find("hook=decreaseVolume", 1, true) then
    hit = true
    if type(VM._onDown) == "function" then pcall(VM._onDown, "VolumeDown") end
  end
  if chunk:find("event=VolumeUp", 1, true) or chunk:find("hook=increaseVolume", 1, true) then
    hit = true
    if type(VM._onUp) == "function" then pcall(VM._onUp, "VolumeUp") end
  end
  return hit
end

--- 启动：开启拦截并可选注册回调
function VM.start(opts)
  opts = opts or {}
  if type(opts.onVolumeDown) == "function" then VM._onDown = opts.onVolumeDown end
  if type(opts.onVolumeUp) == "function" then VM._onUp = opts.onVolumeUp end
  VM.enable()
  local body = read_file(var_dir() .. "/.ziyan_vol_event") or ""
  VM._poll_pos = #body
  VM._running = true
  return true
end

function VM.stop()
  VM._running = false
  return true
end

M.VolumeMonitor = VM
-- 短路径：Input.VolumeDown()
M.VolumeDown = function(...) return VM.VolumeDown(...) end
M.VolumeUp = function(...) return VM.VolumeUp(...) end

----------------------------------------------------------------------
-- Keycode — 系统按键模拟（自研封装；不调用触动 keycode.* 私有模块）
-- 仅复用引擎已有 keyDown/keyUp / pressHomeKey；无能力时诚实返回 false
----------------------------------------------------------------------
local KC = { name = "Keycode", version = "1.0.0" }

local function press_named(key, hold_ms)
  hold_ms = tonumber(hold_ms) or 40
  local native_home = rawget(_G, "__ZIYAN_NATIVE_pressHomeKey")
  if type(native_home) == "function" and (key == "HOME" or key == "home") then
    local ok = pcall(native_home, 1)
    return ok and true or false, "pressHomeKey"
  end
  -- 勿直接调全局 pressHomeKey：compat 包装后可能指向 keycode.home → 递归
  if type(keyDown) == "function" and type(keyUp) == "function"
      and rawget(_G, "__ZIYAN_COMPAT_WRAP_keyDown") ~= true then
    local ok1 = pcall(keyDown, key)
    if type(mSleep) == "function" and rawget(_G, "__ZIYAN_COMPAT_WRAP_mSleep") ~= true then
      mSleep(hold_ms)
    end
    local ok2 = pcall(keyUp, key)
    return (ok1 and ok2) and true or false, "keyDownUp"
  end
  return false, "no_keycode_backend"
end

--- 通用按键：name 如 HOME / Delete / ENTER（依赖底层是否实现）
function KC.press(name, hold_ms)
  name = tostring(name or "")
  if name == "" then return false, "empty" end
  return press_named(name, hold_ms)
end

function KC.home(hold_ms)
  return press_named("HOME", hold_ms)
end

--- 返回键：iOS 无统一物理返回，诚实失败（Android 场景预留）
function KC.back(hold_ms)
  local ok, via = press_named("BACK", hold_ms)
  if ok then return true, via end
  return false, "unsupported_on_ios"
end

function KC.power(hold_ms)
  return press_named("POWER", hold_ms)
end

M.Keycode = KC
M.keycode = function(name, hold_ms) return KC.press(name, hold_ms) end
M.pressHome = function(...) return KC.home(...) end

return M
