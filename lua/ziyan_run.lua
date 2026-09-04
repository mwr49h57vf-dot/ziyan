-- ZiYan Lua bootstrap：对齐触摸精灵脚本环境
-- package.path / toast / mSleep / notifyMessage / main()

local function _ziyan_load_paths()
  -- 先加载与当前 runner 同目录的 helper。rootful 设备可能残留
  -- `/var/jb/usr/lib/ziyan`，若固定 rootless-first，会把本次 rootful 会话
  -- 连接到另一套 IPC var。
  local candidates = {}
  local info = debug and debug.getinfo and debug.getinfo(1, "S")
  local source = info and info.source or ""
  if source:sub(1, 1) == "@" then
    local self_path = source:sub(2)
    local local_paths, changed =
        self_path:gsub("ziyan_run%.lua$", "ziyan_paths.lua")
    if changed > 0 then
      candidates[#candidates + 1] = local_paths
    end
  end
  for _, p in ipairs({
    "/var/jb/usr/lib/ziyan/lib/lua/ziyan_paths.lua",
    "/usr/lib/ziyan/lib/lua/ziyan_paths.lua",
  }) do
    if p ~= candidates[1] then
      candidates[#candidates + 1] = p
    end
  end
  for _, p in ipairs(candidates) do
    local ok, mod = pcall(dofile, p)
    if ok and type(mod) == "table" and mod.root then
      return mod
    end
  end
  return {
    root = function()
      return (io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") and "/var/jb/usr/lib/ziyan")
        or "/usr/lib/ziyan"
    end,
    var = function(self)
      return (self or {})._r and (self._r .. "/var") or "/usr/lib/ziyan/var"
    end,
    lua = function()
      local r = (io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") and "/var/jb/usr/lib/ziyan")
        or "/usr/lib/ziyan"
      return r .. "/lib/lua"
    end,
    scripts = function()
      return "/private/var/mobile/Media/ZiYan"
    end,
  }
end

local ZPaths = _ziyan_load_paths()
local ZIYAN = ZPaths.scripts and ZPaths.scripts() or "/private/var/mobile/Media/ZiYan"
local ZIYAN_ROOT = ZPaths.root()
local ZIYAN_LUA = ZPaths.lua and ZPaths.lua() or (ZIYAN_ROOT .. "/lib/lua")
local ZIYAN_VAR = ZPaths.var and ZPaths.var() or (ZIYAN_ROOT .. "/var")
_G.ZIYAN_ROOT = ZIYAN_ROOT
_G.ZIYAN_VAR = ZIYAN_VAR
-- 8-156：rootless 真实 sleep（禁 busy-wait 抢 CPU / 胀 os.clock）
if not _G.ZIYAN_SLEEP then
  if io.open("/var/jb/bin/sleep", "r") then
    _G.ZIYAN_SLEEP = "/var/jb/bin/sleep"
  elseif io.open("/var/jb/usr/bin/sleep", "r") then
    _G.ZIYAN_SLEEP = "/var/jb/usr/bin/sleep"
  end
end
_G.ZIYAN_LUA = ZIYAN_LUA
_G.ZIYAN_SCRIPTS = ZIYAN
-- 8-161-61：尽早点亮 light（touch/HM 安装前可读），对齐触动短热路径
do
  local lf = io.open(ZIYAN_VAR .. "/.ziyan_light", "r")
  if lf then
    lf:close()
    _G.ZIYAN_LIGHT = true
  end
end
_G.ZIYAN_ZYCV = (ZPaths.zycv and ZPaths.zycv()) or (ZIYAN .. "/ZYCV")
if ZPaths.ensure_zycv then
  pcall(ZPaths.ensure_zycv)
else
  pcall(function()
    local f = io.open(_G.ZIYAN_ZYCV .. "/.keep", "a")
    if f then f:close() end
  end)
end
_G.ZIYAN_SLEEP = (ZPaths.sleep_bin and ZPaths.sleep_bin()) or (
  (io.open("/var/jb/usr/bin/sleep", "r") and "/var/jb/usr/bin/sleep")
  or (io.open("/bin/sleep", "r") and "/bin/sleep")
  or "sleep"
)

package.path = table.concat({
  ZIYAN .. "/lua/?.lua",
  ZIYAN .. "/lua/?/init.lua",
  ZIYAN .. "/ZYCV/res/?.lua",
  ZIYAN .. "/ZYCV/res/?/init.lua",
  ZIYAN .. "/?.lua",
  ZIYAN_LUA .. "/?.lua",
  ZIYAN_LUA .. "/?/init.lua",
  ZIYAN_LUA .. "/ziyan_engine/?.lua",
  ZIYAN_LUA .. "/modules/?.lua",
  package.path,
}, ";")

-- 先提供原始 mSleep，再加载引擎（control 会包装暂停/停止检查点）
-- USB rootless：libc system() 依赖 /bin/sh（不存在）→ os.execute 全失败；用 clock busy-wait
-- LAN rootful：优先真实 sleep，省 CPU
-- 8-161-57：embed 用 C usleep（可被 stop 打断，禁拖死 framecap）
function mSleep(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then
    return
  end
  if _G.ZIYAN_EMBED and type(_G.ziyan_embed_msleep) == "function" then
    pcall(_G.ziyan_embed_msleep, ms)
    return
  end
  local bin = _G.ZIYAN_SLEEP or "sleep"
  local st = os.execute(string.format("'%s' %.3f", bin, ms / 1000.0))
  if st == true or st == 0 then
    return
  end
  local target = os.clock() + (ms / 1000.0)
  while os.clock() < target do
  end
end
-- 8-161-45：供 cv.wait_rep 绕过 SafeExecutor 抬间隔
_G.__ZIYAN_RAW_MSLEEP = mSleep
_G.__ZIYAN_NATIVE_MSLEEP = mSleep

-- 自动加载引擎（含 py_cv → ziyan_cv），res/ 脚本无需手写 dofile/require
pcall(dofile, ZIYAN_LUA .. "/ziyan_te_boot.lua")
-- deb分析 telib Screen 段自研移植（findColor*/getColorRGB/keepScreen 双通道）
do
  local ok, mod = pcall(dofile, ZIYAN_LUA .. "/ziyan_chumo_screen.lua")
  if ok and type(mod) == "table" and type(mod.install) == "function" then
    pcall(mod.install)
  end
end

local CMD_PATH = ZIYAN_VAR .. "/.ziyan_cmd"

local function flatten_toast(s)
  s = tostring(s or ""):gsub("[\r\n]+", " "):gsub("%s+", " ")
  if #s > 180 then
    s = s:sub(1, 180) .. "…"
  end
  if s == "" then
    s = "(空)"
  end
  return s
end

local function write_cmd(kind, payload, ms)
  -- 触动兼容：toast(,1)=1秒；≤10 当秒，否则毫秒；默认 1000ms
  ms = tonumber(ms)
  if ms == nil then
    ms = 1000
  elseif ms > 0 and ms <= 10 then
    ms = ms * 1000
  end
  if ms < 200 then
    ms = 200
  end
  local f = io.open(CMD_PATH, "w")
  if not f then
    return false
  end
  f:write(kind or "toast")
  f:write("\n")
  f:write(flatten_toast(payload))
  f:write("\n")
  f:write(tostring(ms))
  f:write("\n")
  f:close()
  return true
end

local function to_text(any)
  if type(any) == "string" then
    return any
  end
  local ok, inspect = pcall(require, "inspect")
  if ok and inspect then
    return inspect(any)
  end
  return tostring(any)
end

--------------------------------------------------------------------------------
-- 触摸精灵兼容：输出（mSleep 已由 control 包装，勿再覆盖）
--------------------------------------------------------------------------------

function toast(any, ms)
  -- 8-161-60：对齐触动「每圈必见」——只写 .ziyan_cmd（禁 ziyanctl 双写，spawn 会拖慢 toast）
  local text = to_text(any)
  local dur = ms or 1000
  if _G.ZIYAN_EMBED and type(_G.ziyan_embed_toast) == "function" then
    pcall(_G.ziyan_embed_toast, text, dur)
    return
  end
  write_cmd("toast", text, dur)
end

function notifyMessage(any, ms)
  write_cmd("message", to_text(any), ms or 1000)
end

function logDebug(any)
  write_cmd("log", to_text(any), 0)
  io.stderr:write(to_text(any) .. "\n")
end

function scriptStop()
  os.exit(0)
end

--------------------------------------------------------------------------------
-- JSON 便捷封装（同 telib）
--------------------------------------------------------------------------------

function jsonEncode(t)
  local ok, json = pcall(require, "json")
  if not ok or not json then return "{}" end
  local eok, s = pcall(json.encode, t)
  return eok and s or "{}"
end

function jsonDecode(j)
  if type(j) ~= "string" or j == "" or not j:find("%S") then
    return nil
  end
  local ok, json = pcall(require, "json")
  if not ok or not json then return nil end
  local dok, obj = pcall(json.decode, j)
  if dok then return obj end
  return nil
end

--------------------------------------------------------------------------------
-- 尚未接原生引擎的 API：安全空实现，避免脚本直接崩
--------------------------------------------------------------------------------

local function not_impl(name)
  return function(...)
    logDebug("[ZiYan] 未实现: " .. tostring(name))
    return -1, -1
  end
end

_getColor = _getColor or function() return -1 end
_findColor = _findColor or function() return "[]" end
_findImage = _findImage or function() return -1, -1 end
_snapshot = _snapshot or function() return false end
_log = _log or function(s) io.stderr:write(tostring(s) .. "\n") end
_message = _message or function(s, ms) write_cmd("message", tostring(s), ms) end
_toast = _toast or function(s, ms) write_cmd("toast", tostring(s), ms) end

-- 若 chumo_screen 已装则保留；否则兜底（getColorRGB 按触动位布局拆 RGB）
getColor = getColor or function(x, y) return _getColor(x, y) end
if type(getColorRGB) ~= "function" then
  getColorRGB = function(x, y)
    local c = tonumber(_getColor(x, y)) or -1
    if c < 0 then return -1, -1, -1 end
    return math.floor(c / 0x10000) % 256, math.floor(c / 0x100) % 256, c % 256
  end
end

findColor = findColor or not_impl("findColor")
findColorFuzzy = findColorFuzzy or not_impl("findColorFuzzy")
findColorInRegion = findColorInRegion or not_impl("findColorInRegion")
findColorInRegionFuzzy = findColorInRegionFuzzy or not_impl("findColorInRegionFuzzy")
-- 抓色器规范：findMultiColorInRegionFuzzy(主色, 偏点串, degree, x1,y1,x2,y2) → x,y
--（chumo_screen 会再包一层兼容触动 colors 表形）
findMultiColorInRegionFuzzy = findMultiColorInRegionFuzzy or not_impl("findMultiColorInRegionFuzzy")
findMultiColor = findMultiColor or function(...)
  return findMultiColorInRegionFuzzy(...)
end
findImage = findImage or not_impl("findImage")
touchDown = touchDown or function() end
touchMove = touchMove or function() end
touchUp = touchUp or function() end
keyDown = keyDown or function() end
keyUp = keyUp or function() end
appRun = appRun or function() return false end
appKill = appKill or function() return false end
appRunning = appRunning or function() return false end

--------------------------------------------------------------------------------
-- 入口：加载用户脚本，若有 main() 则调用（触摸精灵惯例）
--------------------------------------------------------------------------------

local script = arg and arg[1]
if not script or script == "" then
  io.stderr:write("usage: ziyan_run.lua <script.lua>\n")
  os.exit(2)
end

-- 会话标记：供 ToastBridge 识别「脚本在跑」→ toast 跟 init(orient)
-- .ziyan_project_active：项目已启动；SB 自动重启后仅在此标记存在时才解锁
local SESSION_FILE = ZIYAN_VAR .. "/.ziyan_script_session"
local PROJECT_ACTIVE = ZIYAN_VAR .. "/.ziyan_project_active"
local PID_FILE = ZIYAN_VAR .. "/.ziyan_lua_run.pid"
-- R8.1：Lua5.3 无 os.getpid → 子 shell 的 $PPID 即本进程
local function my_pid()
  for _, sh in ipairs({
    "/var/jb/bin/bash", "/var/jb/usr/bin/bash", "/bin/bash",
    "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/bin/sh",
  }) do
    local f = io.popen(string.format("'%s' -c 'echo $PPID' 2>/dev/null", sh))
    if f then
      local p = tonumber((f:read("*l") or ""):match("%d+"))
      f:close()
      if p and p > 1 then
        return p
      end
    end
  end
  return nil
end
-- R8.1：单实例清理（禁止误杀自身）。仅杀「明确不同 pid」的其它 ziyan_run。
local function kill_other_ziyan_lua()
  local self = my_pid()
  if not self then
    -- 取不到 pid 时绝不扫杀，避免自尽（.166 实测曾 Killed:9）
    return
  end
  pcall(function()
    local cmd = string.format(
      "ps -A -o pid=,args= 2>/dev/null | grep -E 'ziyan_run\\.lua' | grep -v grep | while read p rest; do "
        .. "if [ -n \"$p\" ] && [ \"$p\" -ne %d ]; then kill -9 \"$p\" 2>/dev/null; fi; done",
      self
    )
    os.execute(cmd)
  end)
end
local function mark_session()
  pcall(function()
    local f = io.open(SESSION_FILE, "w")
    if f then
      f:write(tostring(os.time()) .. "\n")
      f:close()
    end
    local p = io.open(PROJECT_ACTIVE, "w")
    if p then
      p:write(tostring(os.time()) .. "\n")
      p:close()
    end
    local a = io.open(ZIYAN_VAR .. "/.ziyan_active", "w")
    if a then
      a:write("1\n")
      a:close()
    end
    local pid = my_pid()
    if pid then
      local pf = io.open(PID_FILE, "w")
      if pf then
        pf:write(tostring(pid) .. "\n")
        pf:close()
      end
    end
    pcall(os.remove, ZIYAN_VAR .. "/.ziyan_vol_disarmed")
    local u = io.open(ZIYAN_VAR .. "/.ziyan_unlock_req", "w")
    if u then
      u:write("1\n")
      u:close()
    end
    pcall(os.remove, ZIYAN_VAR .. "/.ziyan_app_alive")
    pcall(os.remove, ZIYAN_VAR .. "/.ziyan_app_fg")
    pcall(os.remove, ZIYAN_VAR .. "/.ziyan_stop")
    pcall(os.remove, ZIYAN_VAR .. "/.ziyan_paused")
    -- 8-161-99：开跑清粘性停标志，避免上次代杀留下的 user_stopped/stop=1 误杀长跑
    pcall(os.remove, ZIYAN_VAR .. "/.ziyan_user_stopped")
    pcall(function()
      local f = io.open(ZIYAN_VAR .. "/.ziyan_run_intent", "r")
      local body = f and (f:read("*a") or "") or ""
      if f then f:close() end
      if body:find("stop=1", 1, true) then
        body = body:gsub("stop=1", "stop=0")
        local w = io.open(ZIYAN_VAR .. "/.ziyan_run_intent", "w")
        if w then w:write(body); w:close() end
      end
    end)
  end)
end
local function clear_session()
  pcall(os.remove, SESSION_FILE)
  pcall(os.remove, PROJECT_ACTIVE)
  pcall(os.remove, ZIYAN_VAR .. "/.ziyan_unlock_req")
  pcall(os.remove, ZIYAN_VAR .. "/.ziyan_active")
  pcall(os.remove, ZIYAN_VAR .. "/.ziyan_te_running")
  -- 192：停脚本必拆 keep（防 190 类 ACTIVE+KEEP 粘滞拖垮 SB）
  pcall(function()
    if type(_G.keepScreen) == "function" then
      _G.keepScreen(false)
    end
  end)
  pcall(function()
    local f = io.open(ZIYAN_VAR .. "/.ziyan_release_screen", "w")
    if f then f:write("1\n"); f:close() end
  end)
  pcall(os.remove, ZIYAN_VAR .. "/.ziyan_keep_daemon")
  -- R8.3：停脚本 → 快照标记 running=false（断电应急）
  pcall(function()
    if type(_G.__ZIYAN_write_snapshot) == "function" then
      _G.__ZIYAN_write_snapshot({ running = false, reason = "script_end" })
    end
  end)
end

-- R8.3：断电续跑快照（/var/mobile/ZiYan/state_snapshot.json）
-- 溯源：XXTouchNG 快照续跑思想 + 触动会话生命周期（禁止抄码）
local SNAP_DIR = "/var/mobile/ZiYan"
local SNAP_PATH = SNAP_DIR .. "/state_snapshot.json"
local TIP_PATH = SNAP_DIR .. "/jailbreak_need_tip.txt"
local function ensure_snap_dir()
  os.execute("mkdir -p '" .. SNAP_DIR .. "' 2>/dev/null")
end
local function json_escape(s)
  s = tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
  return s
end
local function write_snapshot(extra)
  extra = extra or {}
  ensure_snap_dir()
  local orient = "1"
  pcall(function()
    local f = io.open(ZIYAN_VAR .. "/.ziyan_orient", "r")
    if f then
      orient = (f:read("*l") or "1"):match("%d+") or "1"
      f:close()
    end
  end)
  local keep = (_G.__ZIYAN_KEEP_SCREEN and true) and "1" or "0"
  local running = extra.running
  if running == nil then
    running = true
  end
  local script_name = tostring(script or "?")
  local body = string.format(
    '{"v":1,"ts":%d,"running":%s,"script":"%s","orient":"%s","keepScreen":"%s",'
      .. '"rootless":%s,"progress":"%s","reason":"%s"}\n',
    os.time() or 0,
    running and "true" or "false",
    json_escape(script_name),
    json_escape(orient),
    keep,
    (io.open("/var/jb", "r") and "true" or "false"),
    json_escape(extra.progress or "main_loop"),
    json_escape(extra.reason or "heartbeat")
  )
  local f = io.open(SNAP_PATH, "w")
  if f then
    f:write(body)
    f:close()
  end
  -- rootless：预写重越狱提示（冷启后文件仍在，人工重激活后读 resume_ready）
  if io.open("/var/jb", "r") then
    local tip = string.format(
      "ts=%s\nscheme=rootless\nneed=manual_rejailbreak_after_cold_boot\n"
        .. "snapshot=%s\nscript=%s\nhint=Re-activate Dopamine/Palera1n then open ZiYan\n",
      tostring(os.time()),
      SNAP_PATH,
      script_name
    )
    local tf = io.open(TIP_PATH, "w")
    if tf then
      tf:write(tip)
      tf:close()
    end
  end
end
_G.__ZIYAN_write_snapshot = write_snapshot
_G.__ZIYAN_SNAP_PATH = SNAP_PATH

-- 若 SB 已武装恢复请求，记录到日志（一键恢复由 App/手动重跑脚本）
pcall(function()
  local rf = io.open(ZIYAN_VAR .. "/.ziyan_resume_req", "r")
  if rf then
    local raw = rf:read("*a") or ""
    rf:close()
    local lf = io.open(ZIYAN_VAR .. "/.ziyan_resume_seen", "w")
    if lf then
      lf:write(raw)
      lf:close()
    end
  end
end)

_G.__ZIYAN_mark_session = mark_session
-- R8.1：部署侧负责清僵尸；启动时不做扫杀（防 my_pid/IPC 竞态自尽）
-- kill_other_ziyan_lua()
mark_session()
write_snapshot({ running = true, reason = "script_start", progress = "0" })

-- 包装 mSleep：周期性增量快照（降磁盘：约 20s 一次）
do
  local prev = mSleep
  local last = 0
  function mSleep(ms)
    if type(prev) == "function" then
      prev(ms)
    end
    local now = os.time() or 0
    if now - last >= 60 then
      last = now
      pcall(write_snapshot, { running = true, reason = "mSleep_heartbeat" })
    end
  end
end

local chunk, err = loadfile(script)
if not chunk then
  clear_session()
  io.stderr:write("load error: " .. tostring(err) .. "\n")
  os.exit(1)
end

local ok, runErr = pcall(chunk)
if not ok then
  clear_session()
  io.stderr:write("runtime error: " .. tostring(runErr) .. "\n")
  os.exit(1)
end

if type(main) == "function" then
  local mok, merr = pcall(main)
  clear_session()
  if not mok then
    io.stderr:write("main() error: " .. tostring(merr) .. "\n")
    os.exit(1)
  end
else
  clear_session()
end
