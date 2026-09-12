--[[ ErrorReporter — 错误自动收集（报告目录：Media/ZiYan/ZYCV/res/错误报告）
  设计要点（多 Agent 开发 2026-09-11 需求）：
    · 真实产生错误时立即结构化落盘，不依赖网络/Web 是否可用
    · 报告目录：默认 /private/var/mobile/Media/ZiYan/ZYCV/res/错误报告/<事件ID>/
    · 每份报告：report.json + context.txt + script.txt（有业务脚本时）
    · 保留 3 天：allow-not-delete 未到期日志；删除记录写 _cleanup.log
    · 失败绝不中断业务：所有 io 走 pcall，任何路径都不抛错

  事件类型：script_error（脚本抛错）/ timeout（超时）/ stop（强制停止）/
            hang（卡死）/ crash（进程崩溃，由宿主/守护补写）/
            cold_start（冷启动）/ sb_restart（SpringBoard 重启）/ abnormal_exit（异常退出）

  对外接口：
    M.report(err_type, message, extra)   → 事件ID, 报告目录
    M.handle(script_path, err)           → 包装脚本错误的快捷入口
    M.purge(retention_days)              → 扫描并删除到期报告
    M.list()                             → 未删除报告的事件ID列表
]]

local M = { name = "ErrorReporter", version = "1.0.0" }

-- rootless（.61 等）上 mkdir/ls/rm 可能只存在于 /var/jb/usr/bin，
-- 而 io.popen 的 sh 不继承登录 PATH —— 所有 shell 调用必须自带 PATH 前缀。
local SH_PATH = "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH "


-- 停止事件去重旗标文件名（control.lua 引用；每次新会话启动时清除）
M.STOP_GUARD = ".ziyan_error_reporter_stop_done"

---------------------------------------------------------------------------
-- 平台无关小工具（对齐 modules/ 下其它模块的降级习惯）
---------------------------------------------------------------------------

local function is_utf8()
  local f = _G.string and _G.string.format
  if type(f) ~= "function" then return false end
  return select("#", f("%q", "子砚")) == 1
end

-- 把字符串转成 JSON 字符串字面量（含引号）。
-- 注意：不能用 string.format("%q")——Lua 5.4 会把换行写成 "\"+真实换行（非法 JSON），
-- 5.3 用 \ 后跟十进制数字（同样非法）。这里逐字节手工转义，保证跨版本合法。
-- @return string json, boolean valid_utf8（false 时调用方可决定是否降级 base64）
local function jstr_ex(s)
  s = tostring(s == nil and "" or s)
  local utf8_ok = is_utf8()
  local out = { '"' }
  for i = 1, #s do
    local b = s:byte(i)
    local c = string.char(b)
    if c == '"' then
      out[#out + 1] = '\\"'
    elseif c == "\\" then
      out[#out + 1] = "\\\\"
    elseif c == "\n" then
      out[#out + 1] = "\\n"
    elseif c == "\r" then
      out[#out + 1] = "\\r"
    elseif c == "\t" then
      out[#out + 1] = "\\t"
    elseif b < 0x20 or b == 0x7F then
      out[#out + 1] = string.format("\\u%04X", b)
    elseif b >= 0x80 and not utf8_ok then
      -- 非 UTF-8 环境：把高位字节转义为 \u00XX，至少保持 JSON 可解析
      out[#out + 1] = string.format("\\u%04X", b)
    else
      out[#out + 1] = c
    end
  end
  out[#out + 1] = '"'
  return table.concat(out), utf8_ok
end

local function jstr(s)
  local body = jstr_ex(s)
  return body
end

local function trim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end


--- 统一命令执行正本：lua/modules/zy_shell.lua（2026-09-12 去重；原本地拷贝已删）
--- require 优先；embed/无 package.path 场景按安装路径 dofile 兜底。
local var_dir  -- 前向声明：var_dir 于路径解析区赋值，本文件多处使用

local ZS = (function()
  local ok, mod = pcall(require, "zy_shell")
  if ok and type(mod) == "table" and type(mod.run_capture) == "function" then return mod end
  local base = _G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua"
  for _, p in ipairs({ base .. "/modules/zy_shell.lua",
      "/var/jb/usr/lib/ziyan/lib/lua/modules/zy_shell.lua",
      "/usr/lib/ziyan/lib/lua/modules/zy_shell.lua" }) do
    local f = io.open(p, "r")
    if f then
      f:close()
      local ok2, m2 = pcall(dofile, p)
      if ok2 and type(m2) == "table" and type(m2.run_capture) == "function" then return m2 end
    end
  end
  return nil
end)()
assert(ZS, "zy_shell 加载失败（lua/modules/zy_shell.lua 缺失）")
local run_capture = ZS.run_capture

local function path_exists(path)
  -- 注意：目录用 io.open 判断会成功（POSIX 允许打开目录），必须走 shell test -e；
  -- shell 不可用时退化为 io.open（此时 rm 也不会成功，逻辑仍自洽）。
  local out = run_capture(string.format("test -e '%s' && echo 1 || echo 0", path))
  if out then return trim(out) == "1" end
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function read_text(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

local function write_text(path, body)
  local ok = pcall(function()
    local f = io.open(path, "w")
    if not f then return end
    f:write(body)
    f:close()
  end)
  return ok
end

local function mkdir_p(path)
  run_capture(string.format("mkdir -p '%s'", path))
  local probe = io.open(path .. "/.probe", "w")
  if probe then
    probe:close()
    os.remove(path .. "/.probe")
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- 路径解析
---------------------------------------------------------------------------

local function root_dir()
  if type(_G.ZIYAN_ZYCV) == "string" and #_G.ZIYAN_ZYCV > 0 then
    return _G.ZIYAN_ZYCV
  end
  local p = "/private/var/mobile/Media/ZiYan/ZYCV"
  if io.open(p .. "/res", "r") then return p end
  local legacy = "/var/mobile/Media/ZiYan/ZYCV"
  if io.open(legacy .. "/res", "r") then return legacy end
  return p
end

function M.report_dir()
  return root_dir() .. "/res/错误报告"
end

var_dir = function()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

---------------------------------------------------------------------------
-- 运行信息
---------------------------------------------------------------------------

local function now_iso(ts)
  return os.date("%Y-%m-%d %H:%M:%S", ts or os.time())
end

local function read_os_version()
  -- 直接读 plist（不依赖 shell；rootless 设备无 sysctl/plutil 也能拿到）
  local body = read_text("/System/Library/CoreServices/SystemVersion.plist")
  if body then
    local v = body:match("<key>ProductVersion</key>%s*<string>([^<]+)</string>")
    if v and #v > 0 then return v end
  end
  return nil
end

local function read_arch_hint()
  -- rootless/rootful 以 runtime scheme 标记为准（postinst 写入，root 与 mobile 都可读）
  local marker = read_text("/var/mobile/Library/Preferences/com.ziyan.ziyan.runtime_scheme")
  if marker then
    local scheme = trim(marker:match("^([^\n]*)") or "")
    if scheme == "rootless" then return "iphoneos-arm64", true end
    if scheme == "rootful" then return "iphoneos-arm", false end
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then return "iphoneos-arm64", true end
  return nil, false
end

local function device_info()
  local info = { model = "unknown", os = "unknown", arch = "unknown", rootless = false }

  -- 1) 纯文件来源（无 shell 依赖，rootless 也 100% 可用）
  local osv = read_os_version()
  if osv then info.os = "iOS " .. osv end
  local arch, rootless = read_arch_hint()
  if arch then
    info.arch = arch
    info.rootless = rootless and true or false
  end

  -- 2) 引擎 Device 模块（App/embed 上下文）
  pcall(function()
    local d = _G.Zy and _G.Zy.Device
    if type(d) == "table" and type(d.profile) == "function" then
      local p = d.profile()
      if type(p) == "table" then
        if p.model and tostring(p.model) ~= "" then info.model = tostring(p.model) end
        if p.os and tostring(p.os) ~= "" then info.os = tostring(p.os) end
        if p.arch and tostring(p.arch) ~= "" then info.arch = tostring(p.arch) end
        info.rootless = p.rootless == true
        info.native_w = p.native_w
        info.native_h = p.native_h
        info.orient = p.orient
        info.cpu = p.cpu
        info.cpu_n = p.cpu_n
      end
    end
  end)

  -- 3) 机型：缓存 → sysctl（不可用则保持 unknown，绝不再写坏缓存）
  local marker = var_dir() .. "/.ziyan_error_reporter_device_v2"
  local cached = read_text(marker)
  if cached and #cached > 0 and info.model == "unknown" then
    local model = cached:match("^([^\n]*)")
    if model and #model > 0 and model ~= "unknown" then info.model = model end
  end
  if info.model == "unknown" then
    pcall(function()
      local body = run_capture("sysctl -n hw.machine 2>/dev/null; sysctl -n hw.model 2>/dev/null")
      if not body then return end
      local machine, model = body:match("([^\n]*)\n([^\n]*)")
      if model and #trim(model) > 0 and trim(model) ~= "unknown" then
        info.model = trim(model)
      elseif machine and #trim(machine) > 0 then
        info.model = trim(machine)
      end
    end)
  end

  -- 只在拿到真实机型时写缓存（避免把 unknown 固化）
  if info.model ~= "unknown" then
    write_text(marker, info.model .. "\n" .. info.os .. "\n" .. info.arch .. "\n")
  end
  return info
end

local function version_info()
  local v = { ziyan = "unknown", script = "unknown", commit = "unknown" }
  if type(_G.ZIYAN_VERSION) == "string" and #_G.ZIYAN_VERSION > 0 then
    v.ziyan = _G.ZIYAN_VERSION
  end
  if v.ziyan == "unknown" then
    local body = read_text(var_dir() .. "/.ziyan_version")
    if body and #trim(body) > 0 then v.ziyan = trim(body) end
  end
  pcall(function()
    local out = run_capture("dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null")
    if out then
      local body = trim(out)
      if #body > 0 then v.ziyan = body end
    end
  end)
  if v.ziyan == "unknown" then
    local engine = _G.Zy and _G.Zy.version
    if engine then v.ziyan = "engine-" .. tostring(engine) end
  end
  return v
end

local function runtime_info()
  local r = {
    process = "lua",
    pid = "unknown",
    rss_mb = -1,
    uptime_sec = -1,
    loop = 0,
  }
  pcall(function()
    local body = read_text("/proc/self/status") or ""
    local pid = body:match("^Pid:%s*(%d+)")
    if pid then r.pid = tonumber(pid) end
    local kb = body:match("VmRSS:%s*(%d+)")
    if kb then r.rss_mb = math.floor(tonumber(kb) / 1024) end
  end)
  if r.pid == "unknown" then
    -- iOS 无 /proc：embed 上下文用宿主写入的 pid 文件（framecap/lua_run）
    for _, f in ipairs({ var_dir() .. "/.ziyan_lua_run.pid", var_dir() .. "/.ziyan_framecap_alive" }) do
      local body = read_text(f)
      if body then
        local pid = tonumber(trim(body:match("^([^\n]*)") or ""))
        if pid and pid > 1 then r.pid = pid break end
      end
    end
    if r.pid ~= "unknown" then r.process = _G.ZIYAN_EMBED and "framecap-embed" or "lua" end
  end
  pcall(function()
    if _G.ErrorReporter and _G.ErrorReporter._start_ts then
      r.uptime_sec = os.time() - _G.ErrorReporter._start_ts
    elseif M._start_ts then
      r.uptime_sec = os.time() - M._start_ts
    end
  end)
  pcall(function()
    if _G.SafeExecutor and type(_G.SafeExecutor.state) == "table" then
      r.loop = tonumber(_G.SafeExecutor.state.loop_count) or 0
    elseif _G.HealthMonitor then
      r.loop = tonumber(_G.HealthMonitor.loop_count) or 0
    end
  end)
  return r
end

local function system_diagnostics()
  local d = {}
  pcall(function()
    local body = run_capture(
      "echo \"--df--\"; df -k / /private/var 2>/dev/null | head -4; "
        .. "echo \"--uptime--\"; uptime 2>/dev/null; "
        .. "echo \"--sb--\"; ps -axo pid,comm 2>/dev/null | grep -E 'SpringBoard$| ziYan|ziyan' | head -8")
    if body then d.shell = body:sub(1, 4000) end
  end)
  return d
end

---------------------------------------------------------------------------
-- 事件写入
---------------------------------------------------------------------------

local _seq = 0

local function make_event_id(err_type)
  _seq = _seq + 1
  local ts = os.time()
  local tag = tostring(err_type or "error"):gsub("[^%w_%-]", "_"):sub(1, 24)
  return string.format("zye_%d_%02d_%s", ts, _seq % 100, tag)
end

function M.current_script(path)
  if path ~= nil and #tostring(path) > 0 then
    M._script_path = tostring(path)
  end
  return M._script_path or "unknown"
end

local function script_info()
  local path = M._script_path or "unknown"
  local body = nil
  if path ~= "unknown" then
    body = read_text(path)
  end
  return {
    path = path,
    name = path ~= "unknown" and (path:match("([^/]+)$") or path) or "unknown",
    size = body and #body or -1,
    content = body and body:sub(1, 200000) or nil,
  }
end

--- 写一份错误报告。
--- @param err_type string 事件类型
--- @param message string 错误内容
--- @param extra table|nil 可选：{ phase=, timeout_ms=, stack=, module=, note= }
--- @return string|nil event_id, string|nil dir
function M.report(err_type, message, extra)
  extra = type(extra) == "table" and extra or {}
  local event_id = make_event_id(err_type)
  local base = M.report_dir()
  local dir = base .. "/" .. event_id
  local ok_dir = mkdir_p(dir)
  if not ok_dir then
    -- 目录创建失败退化为单文件，保证不丢证据
    dir = base
  end

  local ts = os.time()
  local dev = device_info()
  local ver = version_info()
  local rt = runtime_info()
  local scr = script_info()
  local phase = tostring(extra.phase or "")

  local report = {
    event_id = event_id,
    time = now_iso(ts),
    time_unix = ts,
    type = tostring(err_type or "unknown"),
    phase = phase,
    message = tostring(message or ""):sub(1, 4000),
    stack = extra.stack and tostring(extra.stack):sub(1, 8000) or nil,
    module = extra.module and tostring(extra.module) or nil,
    note = extra.note and tostring(extra.note) or nil,
    timeout_ms = extra.timeout_ms,
    device = {
      model = dev.model,
      os = dev.os,
      arch = dev.arch,
      rootless = dev.rootless,
      native_w = dev.native_w,
      native_h = dev.native_h,
      orient = dev.orient,
      cpu = dev.cpu,
      cpu_n = dev.cpu_n,
    },
    version = {
      ziyan = ver.ziyan,
      script = ver.script,
      commit = ver.commit,
      engine = _G.Zy and _G.Zy.version or "unknown",
    },
    script = {
      path = scr.path,
      name = scr.name,
      size = scr.size,
    },
    runtime = {
      process = rt.process,
      pid = rt.pid,
      rss_mb = rt.rss_mb,
      uptime_sec = rt.uptime_sec,
      loop = rt.loop,
      lua = _VERSION,
    },
    diagnostics = system_diagnostics(),
  }

  local json = {}
  json[#json + 1] = "{"
  json[#json + 1] = string.format('"event_id":%s,', jstr(report.event_id))
  json[#json + 1] = string.format('"time":%s,', jstr(report.time))
  json[#json + 1] = string.format('"time_unix":%d,', report.time_unix)
  json[#json + 1] = string.format('"type":%s,', jstr(report.type))
  json[#json + 1] = string.format('"phase":%s,', jstr(report.phase))
  json[#json + 1] = string.format('"message":%s,', jstr(report.message))
  if report.stack then
    json[#json + 1] = string.format('"stack":%s,', jstr(report.stack))
  end
  if report.module then
    json[#json + 1] = string.format('"module":%s,', jstr(report.module))
  end
  if report.note then
    json[#json + 1] = string.format('"note":%s,', jstr(report.note))
  end
  if report.timeout_ms then
    json[#json + 1] = string.format('"timeout_ms":%s,', tostring(tonumber(report.timeout_ms) or 0))
  end
  json[#json + 1] = string.format(
    '"device":{"model":%s,"os":%s,"arch":%s,"rootless":%s,"native_w":%s,"native_h":%s,"orient":%s},',
    jstr(report.device.model), jstr(report.device.os), jstr(report.device.arch),
    report.device.rootless and "true" or "false",
    tostring(tonumber(report.device.native_w) or 0), tostring(tonumber(report.device.native_h) or 0),
    tostring(tonumber(report.device.orient) or 0))
  json[#json + 1] = string.format(
    '"version":{"ziyan":%s,"script":%s,"commit":%s,"engine":%s},',
    jstr(report.version.ziyan), jstr(report.version.script), jstr(report.version.commit),
    jstr(report.version.engine))
  json[#json + 1] = string.format(
    '"script":{"path":%s,"name":%s,"size":%d},',
    jstr(report.script.path), jstr(report.script.name), report.script.size)
  json[#json + 1] = string.format(
    '"runtime":{"process":%s,"pid":%s,"rss_mb":%s,"uptime_sec":%s,"loop":%s,"lua":%s},',
    jstr(report.runtime.process), tostring(tonumber(report.runtime.pid) or 0),
    tostring(tonumber(report.runtime.rss_mb) or -1),
    tostring(tonumber(report.runtime.uptime_sec) or -1),
    tostring(tonumber(report.runtime.loop) or 0), jstr(report.runtime.lua))
  json[#json + 1] = string.format('"diagnostics":{"shell":%s}',
    jstr(report.diagnostics.shell or ""))
  json[#json + 1] = "}\n"

  local final = dir .. "/report.json"
  if not ok_dir then
    final = base .. "/" .. event_id .. ".json"
  end
  write_text(final, table.concat(json))

  if ok_dir then
    local ctx = {
      "事件ID: " .. event_id,
      "时间: " .. report.time,
      "类型: " .. report.type,
      "阶段: " .. (phase ~= "" and phase or "(无)"),
      "设备: " .. report.device.model .. " / " .. report.device.os .. " / " .. report.device.arch,
      "ZiYan: " .. report.version.ziyan .. " (engine " .. tostring(report.version.engine) .. ")",
      "业务脚本: " .. report.script.path,
      "进程: pid=" .. tostring(report.runtime.pid) .. " rss=" .. tostring(report.runtime.rss_mb) .. "MB"
        .. " loop=" .. tostring(report.runtime.loop) .. " uptime=" .. tostring(report.runtime.uptime_sec) .. "s",
      "错误内容: " .. report.message,
    }
    if report.stack then ctx[#ctx + 1] = "堆栈: " .. report.stack end
    ctx[#ctx + 1] = ""
    ctx[#ctx + 1] = "---- 系统诊断 ----"
    ctx[#ctx + 1] = tostring(report.diagnostics.shell or "")
    write_text(dir .. "/context.txt", table.concat(ctx, "\n") .. "\n")
    if scr.content then
      write_text(dir .. "/script.txt", scr.content)
    end
  end

  -- Expose the handoff result; retention checks the durable copy again.
  local queued, queue_error = false, "queue_unavailable"
  local q = _G.OfflineQueue
  if type(q) == "table" and type(q.enqueue) == "function" then
    local called, accepted, reason = pcall(q.enqueue, event_id, final)
    queued = called and accepted == true
    if queued then queue_error = nil
    else queue_error = tostring(reason or (not called and accepted) or "queue_commit_failed") end
  end
  M._last_enqueue = {event_id=event_id, ok=queued, error=queue_error}

  -- 每次写报告顺手做一次保留期清理（3 天）
  pcall(M.purge)
  return event_id, final, {queued=queued, queue_error=queue_error}
end

---------------------------------------------------------------------------
-- 脚本错误快捷入口（pcall 的 err 可能带 "file:line: msg" 前缀）
---------------------------------------------------------------------------

function M.handle(script_path, err, extra)
  if script_path then M.current_script(script_path) end
  local msg = tostring(err or "unknown")
  local stack = nil
  local cut = msg:find("stack traceback:", 1, true)
  if cut then
    stack = msg:sub(cut)
    msg = msg:sub(1, cut - 1)
  end
  local exact = type(extra) == "table" and extra or {}
  if stack then exact.stack = stack end
  local event_id, path = M.report("script_error", msg, exact)
  return event_id, path
end

---------------------------------------------------------------------------
-- 生命周期事件（冷启动 / SB 重启 / 异常退出）——由宿主或守护调用
---------------------------------------------------------------------------

local function var_num(name)
  local body = read_text(var_dir() .. "/" .. name)
  if not body then return nil end
  return tonumber(trim(body))
end

--- 进程启动时调用：与上次记录比 SB PID / 上次退出标记，判定冷启动或 SB 重启
function M.on_process_start(reason)
  local sb = var_num(".ziyan_sb_pid")
  local last_exit = read_text(var_dir() .. "/.ziyan_last_exit")
  local last_ts = var_num(".ziyan_last_exit_ts")
  local prev_sb = var_num(".ziyan_error_reporter_last_sb")
  local running = read_text(var_dir() .. "/.ziyan_running")
  local kind, note = "cold_start", tostring(reason or "")
  if sb and prev_sb and sb ~= prev_sb then
    kind = "sb_restart"
    note = string.format("SB %s -> %s", tostring(prev_sb), tostring(sb))
  end
  local exact = { module = "ErrorReporter" }
  if last_exit then
    local seen = last_ts and (os.time() - last_ts) or -1
    exact.note = "last_exit=" .. trim(last_exit) .. " age=" .. tostring(seen) .. "s"
  end
  if running and #trim(running) > 0 then
    -- 上次运行标记仍在 → 上次进程非正常结束（崩溃/被强杀）
    exact.note = (exact.note and (exact.note .. " | ") or "")
      .. "leftover_running=" .. trim(running)
    M.report("abnormal_exit", "上次脚本进程未正常结束（运行标记残留）", exact)
    pcall(os.remove, var_dir() .. "/.ziyan_running")
  end
  M.report(kind, "进程启动: " .. note, exact)
  -- 停止去重旗标：新会话开始即可再次记录停止事件
  pcall(os.remove, var_dir() .. "/" .. (M.STOP_GUARD or ".ziyan_error_reporter_stop_done"))
  write_text(var_dir() .. "/.ziyan_error_reporter_last_sb", tostring(sb or 0))
  return true
end

--- 宿主/守护在脚本被强制停止或异常退出时调用
function M.on_stop(why, extra)
  local exact = type(extra) == "table" and extra or {}
  exact.module = exact.module or "control"
  return M.report("stop", tostring(why or "user_stop"), exact)
end

---------------------------------------------------------------------------
-- 保留期清理（默认 3 天；未到期绝不删除）
---------------------------------------------------------------------------

function M.retention_days()
  return tonumber(M._retention_days) or 3
end

function M.set_retention(days)
  days = tonumber(days)
  if days and days >= 1 then M._retention_days = days end
  return M.retention_days()
end

--- 扫描报告目录，删除创建时间早于保留期的报告目录/文件。
--- @return number deleted, number kept
function M.purge(retention_days)
  local days = tonumber(retention_days) or M.retention_days()
  local cutoff = os.time() - days * 86400
  local base = M.report_dir()
  local deleted, kept = 0, 0
  local log_lines = {}
  local ok = pcall(function()
    local listing = run_capture(string.format("ls -1 '%s' 2>/dev/null", base))
    if not listing then return end
    for name in listing:gmatch("[^\n]+") do
      if name ~= ".probe" and name ~= "_cleanup.log" and not name:match("^%.") then
        local path = base .. "/" .. name
        local ts = nil
        -- 优先取 report.json 内的 time_unix；退化到目录 mtime
        local body = read_text(path .. "/report.json")
        if body then
          ts = tonumber(body:match('"time_unix":(%d+)'))
        end
        if not ts then
          local id_ts = tonumber(name:match("^zye_(%d+)_"))
          if id_ts then ts = id_ts - (id_ts % 1) end
        end
        if not ts then
          local st_out = run_capture(string.format("stat -f %%m '%s' 2>/dev/null", path))
          if st_out then ts = tonumber(trim(st_out)) end
        end
        if ts and ts > 0 then
          local handed_off = false
          local queue = _G.OfflineQueue
          if type(queue) == "table" and type(queue.is_durable) == "function" then
            local checked, durable = pcall(queue.is_durable, name, path .. "/report.json")
            handed_off = checked and durable == true
          end
          if ts < cutoff and handed_off then
            pcall(function()
              os.execute(SH_PATH .. string.format("rm -rf '%s' 2>/dev/null", path))
            end)
            if not path_exists(path) then
              deleted = deleted + 1
              log_lines[#log_lines + 1] = string.format(
                "%s deleted %s (age=%dd)", now_iso(), name, math.floor((os.time() - ts) / 86400))
            else
              kept = kept + 1
            end
          else
            kept = kept + 1
          end
        else
          kept = kept + 1
        end
      end
    end
  end)
  if not ok then
    return 0, 0
  end
  if deleted > 0 then
    local log = io.open(base .. "/_cleanup.log", "a")
    if log then
      log:write(table.concat(log_lines, "\n") .. "\n")
      log:close()
    end
  end
  M._last_purge = { ts = os.time(), deleted = deleted, kept = kept, retention_days = days }
  return deleted, kept
end

function M.list()
  local ids = {}
  pcall(function()
    local listing = run_capture(string.format("ls -1 '%s' 2>/dev/null", M.report_dir()))
    if not listing then return end
    for name in listing:gmatch("[^\n]+") do
      if name:match("^zye_") then ids[#ids + 1] = name end
    end
  end)
  return ids
end

---------------------------------------------------------------------------
-- 安装
---------------------------------------------------------------------------

function M.install()
  _G.ErrorReporter = M
  _G.__ZIYAN_ERROR_REPORTER = M.version
  M._start_ts = M._start_ts or os.time()
  M._script_path = M._script_path or "unknown"
  pcall(function() M.purge() end)
  return M
end

function M.uninstall()
  if _G.ErrorReporter == M then _G.ErrorReporter = nil end
  _G.__ZIYAN_ERROR_REPORTER = nil
  return true
end

return M
