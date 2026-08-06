--[[ 提示：对齐触动 toast 时长语义
  toast(text, 1) → 显示 1 秒（第二参 ≤10 视为「秒」，否则为毫秒）
  默认时长：1 秒（1000ms），与触动 toast(,1) 一致。
  子砚写 .ziyan_cmd，由 SpringBoard ZiYanToastBridge 按 init(0/1/2) 显示。
  样式：透明黑底白字（见 ZiYanToastBridge showToast）。
  每次 toast 前刷新 .ziyan_orient / session，避免开游后横屏错位。
]]
local ZIYAN_VAR = _G.ZIYAN_VAR
if type(ZIYAN_VAR) ~= "string" or ZIYAN_VAR == "" then
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    ZIYAN_VAR = "/var/jb/usr/lib/ziyan/var"
  else
    ZIYAN_VAR = "/usr/lib/ziyan/var"
  end
end
local CMD = ZIYAN_VAR .. "/.ziyan_cmd"
local ORIENT_FILE = ZIYAN_VAR .. "/.ziyan_orient"
local SESSION_FILE = ZIYAN_VAR .. "/.ziyan_script_session"

local M = {}

--- 触动兼容：1..10 → 秒×1000；>10 → 已是毫秒；默认 1000ms（1 秒）
local function ms_norm(ms)
  ms = tonumber(ms)
  if ms == nil then
    return 1000
  end
  if ms > 0 and ms <= 10 then
    ms = ms * 1000
  end
  -- 下限 200ms，允许 toast(,1)=1000 原样生效（旧版曾抬到 600）
  if ms < 200 then
    ms = 200
  end
  return ms
end

local function read_file_orient()
  local f = io.open(ORIENT_FILE, "r")
  if not f then
    return nil, 0, 0
  end
  local o = tonumber((f:read("*l") or ""):match("-?%d+"))
  local lw = tonumber((f:read("*l") or ""):match("%d+")) or 0
  local lh = tonumber((f:read("*l") or ""):match("%d+")) or 0
  f:close()
  if o == nil or o < 0 or o > 2 then
    return nil, lw, lh
  end
  return o, lw, lh
end

--- 开 toast 前与游戏屏对齐（softSync + 可选 gameSync，防开游后错位）
--- R8.4.3：未显式 init 时禁止把文件里的横屏降成 0（旁路 lua toast 曾搞坏 .166）
local function refresh_toast_orient()
  pcall(function()
    if type(softSync) == "function" then
      softSync()
    elseif type(ZiYanOrient) == "table" and type(ZiYanOrient.soft_sync) == "function" then
      ZiYanOrient.soft_sync()
    end
  end)
  local orient = tonumber(_G.__ZIYAN_ORIENT)
  if orient == nil then
    orient = tonumber(_G.__ZIYAN_TE_ORIENT)
  end
  local fo, flw, flh = read_file_orient()
  if not _G.__ZIYAN_INIT_CALLED then
    if (orient == nil or orient == 0) and (fo == 1 or fo == 2) then
      orient = fo
    end
  end
  if orient == nil then
    orient = fo or 1
  end
  pcall(function()
    local bid = _G.__ZIYAN_LAST_BID
    if type(gameSync) == "function" and bid then
      gameSync(orient, bid)
    elseif type(syncGameScreen) == "function" and bid then
      syncGameScreen(orient, bid)
    end
  end)
  local lw, lh = 0, 0
  if type(getScreenSize) == "function" then
    lw, lh = getScreenSize()
  end
  lw, lh = tonumber(lw) or 0, tonumber(lh) or 0
  if lw < 2 or lh < 2 then
    lw, lh = flw, flh
  end
  -- 未 init 且会话已是横屏：只刷新 session，不降级写 0
  if (not _G.__ZIYAN_INIT_CALLED) and orient == 0 and (fo == 1 or fo == 2) then
    orient = fo
    if flw > 0 and flh > 0 then
      lw, lh = flw, flh
    end
  end
  pcall(function()
    if (not _G.__ZIYAN_INIT_CALLED) and orient == 0 and (fo == 1 or fo == 2) then
      return
    end
    local f = io.open(ORIENT_FILE, "w")
    if f then
      f:write(tostring(orient) .. "\n")
      if lw > 0 and lh > 0 then
        f:write(tostring(lw) .. "\n" .. tostring(lh) .. "\n")
      end
      f:close()
    end
  end)
  pcall(function()
    local f = io.open(SESSION_FILE, "w")
    if f then f:write(tostring(os.time()) .. "\n"); f:close() end
  end)
  return orient
end

-- 8-161-89：同文案 ≥1.2s（旧 2.5s 叠 SB 节流体感「卡 toast」；仍防 2Hz 风暴）
local _last_toast_text = nil
local _last_toast_t = 0
local TOAST_SAME_MIN_SEC = 1.2

local function write_cmd(kind, any, ms)
  local text = tostring(any or "")
  local now = os.clock() or 0
  if kind == "toast" and _last_toast_text == text and (now - _last_toast_t) < TOAST_SAME_MIN_SEC then
    return
  end
  _last_toast_text = text
  _last_toast_t = now

  local orient = refresh_toast_orient()
  -- 8-161-89：先写 tmp 再 rename，配合 SB rename 认领
  local tmp = CMD .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    f = io.open(CMD, "w")
    if not f then return end
  end
  -- kind \n text \n ms \n orient
  f:write(tostring(kind or "toast") .. "\n")
  f:write(text .. "\n")
  f:write(tostring(ms_norm(ms)) .. "\n")
  f:write(tostring(orient) .. "\n")
  f:close()
  if tmp ~= CMD then
    os.rename(tmp, CMD)
  end
  -- 8-150/96：Toast 双写 shm（经 UTF-8 文件，禁 shell 传中文）
  pcall(function()
    local shm = _G.ZiYanShm
    if type(shm) == "table" and type(shm.write_toast) == "function" then
      shm.write_toast(text, ms_norm(ms))
    end
  end)
end

function M.install()
  function toast(any, ms)
    write_cmd("toast", any, ms)
  end
  function notifyMessage(any, ms)
    write_cmd("message", any, ms)
  end
  function dialog(any, timeout)
    local sec = tonumber(timeout) or 0
    local ms = sec > 0 and (sec * 1000) or 1000
    write_cmd("toast", any, ms)
  end
  return M
end

return M
