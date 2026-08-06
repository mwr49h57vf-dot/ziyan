--[[
  8-154：ControlShm 双写桥（ziyanctl）
  - 热路径默认开启（存在 .ziyan_control_shm 或可写 var）
  - 写 .ziyan_shm_disabled 可关；写 .ziyan_shm_lua_off 可关热双写
  - 禁止阻塞：失败静默回退文件 IPC
]]

local M = {}

local function resolve_var()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function resolve_ctl()
  local cands = {
    "/var/jb/usr/lib/ziyan/bin/ziyanctl",
    "/usr/lib/ziyan/bin/ziyanctl",
  }
  for i = 1, #cands do
    local f = io.open(cands[i], "r")
    if f then
      f:close()
      return cands[i]
    end
  end
  return nil
end

local function shm_ok()
  local var = resolve_var()
  if io.open(var .. "/.ziyan_shm_disabled", "r") then
    return false
  end
  return resolve_ctl() ~= nil
end

--- 找色/触控热路径：默认开；.ziyan_shm_lua_off 可关；兼容旧 .ziyan_shm_lua 强制开
local function shm_hot_ok()
  if not shm_ok() then
    return false
  end
  if _G.__ZIYAN_SHM_LUA == false then
    return false
  end
  local var = resolve_var()
  if io.open(var .. "/.ziyan_shm_lua_off", "r") then
    return false
  end
  if _G.__ZIYAN_SHM_LUA == true then
    return true
  end
  -- 默认 ON（T2 验收：热路径走 shm 双写）
  return true
end

--- 转义单引号供 shell
local function q(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

function M.available()
  return shm_ok()
end

--- 读控制标志：优先 mmap 文件 flags（offset=16），失败回退 .ziyan_paused/.ziyan_stop
function M.read_control_flags_fast()
  local var = resolve_var()
  local flags = { paused = false, stopped = false }
  local f = io.open(var .. "/.ziyan_control_shm", "rb")
  if f then
    f:seek("set", 16) -- magic+version+timestamp → flags(uint32 LE)
    local b = f:read(4)
    f:close()
    if type(b) == "string" and #b == 4 then
      local v = b:byte(1) + b:byte(2) * 256 + b:byte(3) * 65536 + b:byte(4) * 16777216
      -- STOP=bit1(2), PAUSED=bit2(4)
      flags.stopped = (math.floor(v / 2) % 2) == 1
      flags.paused = (math.floor(v / 4) % 2) == 1
      return flags
    end
  end
  -- fallback 文件 IPC
  local pf = io.open(var .. "/.ziyan_paused", "r")
  if pf then pf:close(); flags.paused = true end
  local sf = io.open(var .. "/.ziyan_stop", "r")
  if sf then sf:close(); flags.stopped = true end
  return flags
end

function M.read_control_flags()
  if not shm_ok() then
    return M.read_control_flags_fast()
  end
  local ctl = resolve_ctl()
  local h = io.popen(ctl .. " shm read_control_flags 2>/dev/null")
  local out = h and h:read("*a") or ""
  if h then h:close() end
  local paused = tonumber(out:match("paused=(%d)")) == 1
  local stopped = tonumber(out:match("stopped=(%d)")) == 1
  if out:find("paused=") then
    return { paused = paused, stopped = stopped }
  end
  return M.read_control_flags_fast()
end

--- 写控制标志：走 ziyanctl 双写 shm+文件；失败回退直接写文件
function M.write_control_flags(paused, stopped)
  local var = resolve_var()
  local ctl = resolve_ctl()
  local p = paused and 1 or 0
  local s = stopped and 1 or 0
  if shm_ok() then
    local cmd = string.format(
      "%s shm write_control_flags %d %d >/dev/null 2>&1",
      ctl, p, s
    )
    local ok = pcall(os.execute, cmd)
    if ok then
      return true
    end
  end
  -- fallback 文件 IPC
  if paused then
    local f = io.open(var .. "/.ziyan_paused", "w")
    if f then f:write("1\n"); f:close() end
  else
    os.remove(var .. "/.ziyan_paused")
  end
  if stopped then
    local f = io.open(var .. "/.ziyan_stop", "w")
    if f then f:write("1\n"); f:close() end
  else
    os.remove(var .. "/.ziyan_stop")
  end
  return true
end

function M.write_color(main, points_json, fuzzy, x1, y1, x2, y2, nonce)
  if not shm_hot_ok() then
    return false
  end
  local ctl = resolve_ctl()
  -- 同步写（mmap <5ms）；禁止 &，避免文件先被消费后再落 shm 造成双次找色
  local cmd = string.format(
    "%s shm write_color %s %s %s %s %s %s %s %s >/dev/null 2>&1",
    ctl,
    tostring(tonumber(main) or 0),
    tostring(tonumber(fuzzy) or 90),
    tostring(tonumber(x1) or 0),
    tostring(tonumber(y1) or 0),
    tostring(tonumber(x2) or -1),
    tostring(tonumber(y2) or -1),
    tostring(tonumber(nonce) or 0),
    q(points_json)
  )
  pcall(os.execute, cmd)
  return true
end

function M.write_touch(typ, x, y, hold_ms, finger, nonce)
  if not shm_hot_ok() then
    return false
  end
  local ctl = resolve_ctl()
  local cmd = string.format(
    "%s shm write_touch %d %d %d %d %d %s >/dev/null 2>&1",
    ctl,
    tonumber(typ) or 1,
    math.floor(tonumber(x) or 0),
    math.floor(tonumber(y) or 0),
    tonumber(hold_ms) or 90,
    tonumber(finger) or 1,
    tostring(tonumber(nonce) or 0)
  )
  pcall(os.execute, cmd)
  return true
end

function M.write_toast(text, ms)
  if not shm_ok() then
    return false
  end
  local ctl = resolve_ctl()
  if not ctl then
    return false
  end
  text = tostring(text or "")
  ms = tonumber(ms) or 1500
  -- 8-161-96：中文等非 ASCII 禁止塞进 shell argv（会变成 ÁôªÂΩï 一类 MacRoman 乱码）
  -- 改写 UTF-8 临时文件 → write_toast_file
  local var = resolve_var()
  local payload = var .. "/.ziyan_toast_shm_payload"
  local f = io.open(payload, "wb")
  if not f then
    return false
  end
  f:write(text)
  f:close()
  local cmd = string.format(
    "%s shm write_toast_file %d %s >/dev/null 2>&1",
    ctl,
    ms,
    q(payload)
  )
  local ok = pcall(os.execute, cmd)
  pcall(os.remove, payload)
  return ok and true or false
end

function M.heartbeat(name)
  if not shm_ok() then
    return false
  end
  local ctl = resolve_ctl()
  pcall(os.execute, string.format(
    "%s shm heartbeat %s >/dev/null 2>&1",
    ctl,
    q(name or "lua")
  ))
  return true
end

_G.__ZIYAN_SHM_AVAILABLE = M.available()
_G.ZiYanShm = M

return M
