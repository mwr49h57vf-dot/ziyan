--[[ HealthMonitor — 24/7 全自动化健康监控系统
  在 while true 循环的 mSleep 中透明注入，自动检测并修复 9 类渐进式退化。
  用户脚本零感知，零修改。

  检查频率分层：
    每 10 轮 (~5s):   快速检查 — 内存趋势、热降频、toast 抑制
    每 100 轮 (~50s):  中等检查 — 磁盘空间、文件描述符、计时器漂移、网络
    每 1000 轮 (~8min): 深度检查 — 游戏存活、电量、GC、IPC 清理
    每 10000 轮 (~83min): 预防性重启 — 清理累积隐性垃圾
]]

local M = { name = "HealthMonitor", version = "1.1.0" }

---------------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------------
M.PULSE_FAST   = 10      -- 快速检查间隔（轮）
M.PULSE_MEDIUM = 100     -- 中等检查间隔（轮）
M.PULSE_DEEP   = 1000    -- 深度检查间隔（轮）
M.PULSE_REBOOT = 10000   -- 预防性重启间隔（轮）

-- 内存趋势
M.MEM_SLOPE_WARN  = 1.0   -- MB/10min 告警
M.MEM_SLOPE_GC    = 3.0   -- MB/10min 强制 GC
M.MEM_SLOPE_EXIT  = 5.0   -- MB/10min 主动退出（让守护重启）
M.MEM_RSS_CRITICAL = 140  -- 绝对 RSS 熔断线（MB）

-- 磁盘
M.DISK_CRITICAL = 95      -- 紧急停止
M.DISK_SEVERE   = 90      -- 删除所有截图
M.DISK_WARN     = 80      -- 清理 12h 前
M.DISK_NOTE     = 70      -- 清理 24h 前

-- 文件描述符
M.FD_WARN  = 200
M.FD_EXIT  = 500

-- Toast 抑制（每轮 toast 会导致 UIKit 内存累积）
M.TOAST_MIN_INTERVAL_MS = 3000  -- 同一消息最小间隔
M.TOAST_SUPPRESS_SEARCHING = true  -- 抑制 "searching" 类 toast

---------------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------------
M.loop_count = 0
M.start_time = 0
M.health_status = "ok"         -- ok / warn / degraded / critical
M.health_history = {}          -- 最近 100 条事件
M._last_toast_ts = {}          -- {msg_key → timestamp} 防重复 toast
M._last_toast_msg = ""         -- 上次 toast 内容
M._last_toast_time = 0         -- 上次 toast 时间
M._cycle_ms = 500              -- 当前动态间隔（供 SafeExecutor 读写）
M._degraded = false            -- 是否已降级
M._last_find_ms = 0            -- 最近一次找色耗时（ms）
M._no_find_count = 0           -- 连续未找到计数
M._max_no_find_cooldown = 10   -- 连续 N 次未找到 → 进入冷却期

-- 内存趋势采样
M._mem_samples = {}            -- {t=os.time(), rss=MB}
M._mem_window_sec = 600        -- 10 分钟窗口

-- 计时器漂移
M._drift_start_wall = 0
M._drift_expected_elapsed = 0

-- 网络
M._net_fail_count = 0
M._net_offline_mode = false
M._net_last_check = 0

-- 文件描述符
M._fd_last_check = 0
M._fd_last_count = 0

---------------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------------

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function media_dir()
  if type(_G.ZIYAN_SCRIPTS) == "string" and #_G.ZIYAN_SCRIPTS > 0 then
    return _G.ZIYAN_SCRIPTS
  end
  return "/private/var/mobile/Media/ZiYan"
end

-- 获取当前进程 RSS（MB），通过 /proc/self/ 或 task_info
local function get_rss_mb()
  -- 方案1：/proc/self/status（iOS 越狱后可用）
  local f = io.open("/proc/self/status", "r")
  if f then
    local body = f:read("*a") or ""
    f:close()
    local vm = body:match("VmRSS:%s*(%d+)")
    if vm then
      return math.floor(tonumber(vm) / 1024)  -- kB → MB
    end
  end
  -- 方案2：ps 命令
  local p = io.popen("ps -o rss= -p $$ 2>/dev/null")
  if p then
    local line = p:read("*l") or ""
    p:close()
    local kb = tonumber(line:match("^(%d+)"))
    if kb then
      return math.floor(kb / 1024)
    end
  end
  return 0
end

-- 获取文件描述符数量
local function get_fd_count()
  local p = io.popen("ls /proc/$$/fd 2>/dev/null | wc -l")
  if p then
    local line = p:read("*l") or ""
    p:close()
    return tonumber(line:match("^(%d+)")) or 0
  end
  return 0
end

-- 获取磁盘使用率
local function get_disk_usage_pct()
  local p = io.popen("df -k '" .. media_dir() .. "' 2>/dev/null | tail -1")
  if not p then return 0 end
  local line = p:read("*l") or ""
  p:close()
  local pct = line:match("(%d+)%%")
  return tonumber(pct) or 0
end

-- 获取电量
local function get_battery_pct()
  local f = io.open("/private/var/mobile/Library/BatteryLife/CurrentCapacity.txt", "r")
  if f then
    local val = tonumber(f:read("*l"))
    f:close()
    if val then return val end
  end
  -- 备用：ioreg
  local p = io.popen("ioreg -r -c AppleSmartBattery | grep '\"CurrentCapacity\"' | awk '{print $NF}' 2>/dev/null")
  if p then
    local val = tonumber(p:read("*l"))
    p:close()
    if val then return val end
  end
  return 100
end

-- 检查是否在充电
local function is_charging()
  local p = io.popen("ioreg -r -c AppleSmartBattery | grep '\"ExternalConnected\"' | grep -c Yes 2>/dev/null")
  if p then
    local val = tonumber(p:read("*l"))
    p:close()
    return (val or 0) > 0
  end
  return true
end

-- ping 网关检测网络
local function ping_gateway()
  local p = io.popen("route -n get default 2>/dev/null | grep gateway | awk '{print $2}'")
  if not p then return false end
  local gw = p:read("*l") or ""
  p:close()
  if gw == "" then return false end
  local ok = os.execute("ping -c1 -t2 " .. gw .. " >/dev/null 2>&1")
  return ok == 0 or ok == true
end

-- 写入健康日志
local function health_log_path()
  return var_dir() .. "/.ziyan_health_log.jsonl"
end

local function write_health_log(event, detail)
  local line = string.format(
    '{"ts":%d,"loop":%d,"rss":%d,"event":%q,"detail":%q,"status":%q}\n',
    os.time(), M.loop_count, get_rss_mb(), tostring(event),
    tostring(detail or ""):sub(1, 100), M.health_status)
  pcall(function()
    local f = io.open(health_log_path(), "a")
    if f then f:write(line); f:close() end
  end)
end

---------------------------------------------------------------------------
-- 检查器 1: MemoryTrend — 内存趋势监控
---------------------------------------------------------------------------
local function check_memory_trend()
  local rss = get_rss_mb()
  if rss <= 0 then return "ok" end

  -- 记录采样
  table.insert(M._mem_samples, { t = os.time(), rss = rss })
  local cutoff = os.time() - M._mem_window_sec
  while #M._mem_samples > 0 and M._mem_samples[1].t < cutoff do
    table.remove(M._mem_samples, 1)
  end

  -- 绝对 RSS 熔断
  if rss > M.MEM_RSS_CRITICAL then
    M.health_status = "critical"
    write_health_log("rss_critical", string.format("rss=%dMB", rss))
    return "exit"
  end

  -- 计算斜率
  if #M._mem_samples >= 2 then
    local first = M._mem_samples[1]
    local last = M._mem_samples[#M._mem_samples]
    local dt_min = (last.t - first.t) / 60
    if dt_min >= 1 then
      local slope = (last.rss - first.rss) / dt_min * 10  -- MB/10min
      if slope > M.MEM_SLOPE_EXIT then
        M.health_status = "critical"
        write_health_log("mem_leak_exit", string.format("slope=%.1f rss=%d", slope, rss))
        return "exit"
      elseif slope > M.MEM_SLOPE_GC then
        M.health_status = "degraded"
        collectgarbage("collect")
        write_health_log("mem_leak_gc", string.format("slope=%.1f rss=%d", slope, rss))
        return "gc"
      elseif slope > M.MEM_SLOPE_WARN then
        M.health_status = "warn"
        write_health_log("mem_leak_warn", string.format("slope=%.1f rss=%d", slope, rss))
        return "warn"
      end
    end
  end

  -- 恢复检测
  if M.health_status == "warn" or M.health_status == "degraded" then
    if rss < 50 then
      M.health_status = "ok"
      write_health_log("mem_recovered", string.format("rss=%d", rss))
    end
  end

  return "ok"
end

---------------------------------------------------------------------------
-- 检查器 2: DiskGuard — 磁盘空间保护
---------------------------------------------------------------------------
local function check_disk()
  local pct = get_disk_usage_pct()
  if pct <= 0 then return "ok" end

  if pct >= M.DISK_CRITICAL then
    M.health_status = "critical"
    write_health_log("disk_critical", string.format("pct=%d", pct))
    return "critical"
  elseif pct >= M.DISK_SEVERE then
    -- 删除所有截图
    pcall(function()
      os.execute("find '" .. media_dir() .. "/ZYCV' -name '*.png' -delete 2>/dev/null")
      os.execute("find '" .. var_dir() .. "' -name '.ziyan_*.tmp.*' -delete 2>/dev/null")
    end)
    write_health_log("disk_severe", string.format("pct=%d", pct))
    return "severe"
  elseif pct >= M.DISK_WARN then
    pcall(function()
      os.execute("find '" .. media_dir() .. "/ZYCV' -name '*.png' -mmin +720 -delete 2>/dev/null")
    end)
    write_health_log("disk_warn", string.format("pct=%d", pct))
    return "warn"
  elseif pct >= M.DISK_NOTE then
    pcall(function()
      os.execute("find '" .. media_dir() .. "/ZYCV' -name '*.png' -mmin +1440 -delete 2>/dev/null")
    end)
    return "note"
  end
  return "ok"
end

---------------------------------------------------------------------------
-- 检查器 3: FDLeakDetector — 文件描述符泄漏
---------------------------------------------------------------------------
local function check_fd_leak()
  local count = get_fd_count()
  if count <= 0 then return "ok" end

  if count >= M.FD_EXIT then
    M.health_status = "critical"
    write_health_log("fd_leak_exit", string.format("count=%d", count))
    return "exit"
  elseif count >= M.FD_WARN then
    M.health_status = "warn"
    write_health_log("fd_leak_warn", string.format("count=%d", count))
    return "warn"
  end
  M._fd_last_count = count
  return "ok"
end

---------------------------------------------------------------------------
-- 检查器 4: TimerDrift — 计时器漂移校正
---------------------------------------------------------------------------
local function check_timer_drift()
  if M._drift_start_wall == 0 then
    M._drift_start_wall = os.time()
    M._drift_expected_elapsed = 0
    return "ok"
  end

  local actual_elapsed = (os.time() - M._drift_start_wall) * 1000
  local drift = actual_elapsed - M._drift_expected_elapsed

  if drift > 60000 then
    -- 漂移超过 60 秒：重新同步
    M._drift_start_wall = os.time()
    M._drift_expected_elapsed = 0
    write_health_log("timer_resync", string.format("drift=%.0fs", drift / 1000))
    return "resync"
  elseif drift > 30000 then
    write_health_log("timer_drift", string.format("drift=%.0fs", drift / 1000))
    return "skip"
  elseif drift > 5000 then
    return "adjust"
  end
  return "ok"
end

---------------------------------------------------------------------------
-- 检查器 5: NetworkHealth — 网络健康
---------------------------------------------------------------------------
local function check_network()
  if M._net_offline_mode then
    if os.time() - M._net_last_check > 300 then
      if ping_gateway() then
        M._net_fail_count = 0
        M._net_offline_mode = false
        write_health_log("net_recovered")
        return "recovered"
      end
      M._net_last_check = os.time()
    end
    return "offline"
  end

  if ping_gateway() then
    M._net_fail_count = 0
    return "ok"
  end

  M._net_fail_count = M._net_fail_count + 1
  if M._net_fail_count >= 10 then
    M._net_offline_mode = true
    write_health_log("net_offline", "fail_count=10")
    return "offline"
  elseif M._net_fail_count >= 5 then
    write_health_log("net_hard_recover", "fail_count=5")
    return "recover_hard"
  elseif M._net_fail_count >= 3 then
    write_health_log("net_soft_recover", "fail_count=3")
    return "recover_soft"
  end
  return "retry"
end

---------------------------------------------------------------------------
-- 检查器 6: PowerGuard — 电量保护
---------------------------------------------------------------------------
local function check_power()
  local pct = get_battery_pct()
  local charging = is_charging()

  if pct < 5 and not charging then
    M.health_status = "critical"
    write_health_log("battery_critical", string.format("pct=%d charging=%s", pct, tostring(charging)))
    return "critical"
  elseif pct < 10 and not charging then
    M.health_status = "degraded"
    write_health_log("battery_low", string.format("pct=%d", pct))
    return "pause"
  elseif pct < 20 and not charging then
    M.health_status = "warn"
    write_health_log("battery_warn", string.format("pct=%d", pct))
    return "throttle"
  end

  -- 充电恢复
  if charging and (M.health_status == "degraded" or M.health_status == "warn") then
    M.health_status = "ok"
    write_health_log("battery_charging", string.format("pct=%d", pct))
  end

  return "ok"
end

---------------------------------------------------------------------------
-- 检查器 7: ThermalGuard — 热降频检测
---------------------------------------------------------------------------
local function check_thermal()
  if M._last_find_ms <= 0 then return "ok" end

  if M._last_find_ms > 200 then
    M.health_status = "degraded"
    M._cycle_ms = math.min(M._cycle_ms * 2, 5000)
    write_health_log("thermal_slow", string.format("find_ms=%d", M._last_find_ms))
    return "slow"
  elseif M._last_find_ms > 100 then
    M.health_status = "warn"
    M._cycle_ms = math.min(M._cycle_ms * 1.5, 2000)
    write_health_log("thermal_warn", string.format("find_ms=%d", M._last_find_ms))
    return "warn"
  elseif M._last_find_ms < 50 and M.health_status == "degraded" then
    M.health_status = "ok"
    M._cycle_ms = math.max(M._cycle_ms / 2, 500)
    if M._cycle_ms <= 500 then M._degraded = false end
    write_health_log("thermal_recovered", string.format("find_ms=%d", M._last_find_ms))
  end

  return "ok"
end

---------------------------------------------------------------------------
-- 检查器 8: GameHealth — 游戏存活检测
---------------------------------------------------------------------------
local function check_game_health()
  -- 检查游戏是否在前台
  local front_bid = ""
  if type(_G.frontAppBid) == "function" then
    front_bid = tostring(_G.frontAppBid() or "")
  end

  -- 如果定义了默认 BID 且不在前台，尝试恢复
  local default_bid = ""
  if type(_G.gameDefaultBid) == "function" then
    default_bid = tostring(_G.gameDefaultBid() or "")
  end

  if default_bid ~= "" and front_bid ~= "" and front_bid ~= default_bid then
    -- 游戏不在前台
    write_health_log("game_not_front", string.format("front=%s expected=%s", front_bid, default_bid))
    -- 尝试恢复游戏
    if type(_G.gameRecover) == "function" then
      pcall(_G.gameRecover, default_bid, 1)
    elseif type(_G.runApp) == "function" then
      pcall(_G.runApp, default_bid)
      if type(_G.mSleep) == "function" then pcall(_G.mSleep, 3000) end
    end
    return "recovered"
  end

  -- 连续找色失败超过 100 次 → 可能游戏异常
  if M._no_find_count > 100 then
    write_health_log("game_no_find_100", string.format("no_find=%d", M._no_find_count))
    return "warn"
  end

  return "ok"
end

---------------------------------------------------------------------------
-- 检查器 9: AntiPattern — 反作弊行为随机化
---------------------------------------------------------------------------
local function check_anti_pattern()
  -- 每 500 轮随机暂停 5-30 秒（模拟人类休息）
  if M.loop_count > 0 and M.loop_count % 500 == 0 then
    local pause_ms = math.random(5000, 30000)
    write_health_log("anti_pattern_pause", string.format("pause_ms=%d", pause_ms))
    return pause_ms
  end
  return 0
end

---------------------------------------------------------------------------
-- Toast 抑制（防止每轮 toast 导致 UIKit 内存累积）
---------------------------------------------------------------------------
local _original_toast = nil

local function smart_toast(msg, duration)
  -- 抑制 "searching" 类无意义 toast
  local msg_str = tostring(msg or "")
  if M.TOAST_SUPPRESS_SEARCHING and msg_str:find("earch", 1, true) then
    -- 只在首次或每 30 轮输出一次
    if M.loop_count % 30 ~= 0 then
      return
    end
  end

  -- 同消息防抖
  local now = os.time() * 1000
  local key = msg_str:sub(1, 40)
  local last = M._last_toast_ts[key] or 0
  if (now - last) < M.TOAST_MIN_INTERVAL_MS then
    return
  end
  M._last_toast_ts[key] = now

  -- 调用原始 toast
  if _original_toast then
    _original_toast(msg_str, duration)
  end
end

---------------------------------------------------------------------------
-- 保存状态快照（供守护进程恢复）
---------------------------------------------------------------------------
local function save_snapshot(reason)
  local snapshot = {
    ts = os.time(),
    reason = tostring(reason or "unknown"),
    loop_count = M.loop_count,
    rss = get_rss_mb(),
    health_status = M.health_status,
    script = _G.__ZIYAN_CURRENT_SCRIPT or "unknown",
    bid = type(_G.gameDefaultBid) == "function" and tostring(_G.gameDefaultBid()) or "",
  }
  local path = var_dir() .. "/.ziyan_health_snapshot.json"
  pcall(function()
    local f = io.open(path, "w")
    if f then
      -- 手动构建 JSON（避免依赖 json 模块）
      f:write(string.format(
        '{"ts":%d,"reason":%q,"loop":%d,"rss":%d,"status":%q,"script":%q,"bid":%q}\n',
        snapshot.ts, snapshot.reason, snapshot.loop_count,
        snapshot.rss, snapshot.health_status, snapshot.script, snapshot.bid))
      f:close()
    end
  end)
  write_health_log("snapshot_saved", reason)
end

---------------------------------------------------------------------------
-- 主动退出（让守护进程重启）
---------------------------------------------------------------------------
local function proactive_exit(reason)
  -- 8-161-99：禁止主动 os.exit——业务未调 lua_exit() 不得停（对照触动长跑）
  save_snapshot(reason)
  write_health_log("proactive_exit_suppressed", tostring(reason or ""))
  if type(_G.keepScreen) == "function" then pcall(_G.keepScreen, false) end
  collectgarbage("collect")
  M._degraded = true
end

---------------------------------------------------------------------------
-- 核心: pulse() — 每轮 mSleep 中调用
---------------------------------------------------------------------------
function M.pulse()
  M.loop_count = M.loop_count + 1

  -- 8-142：进程心跳（终稿 §4.1），供 ZiyanProcessWatchdog 观测 lua 存活
  pcall(function()
    local now = os.time()
    if (M._last_hb_ts or 0) + 3 <= now then
      M._last_hb_ts = now
      local f = io.open(var_dir() .. "/.ziyan_heartbeat_lua5.3", "w")
      if f then
        f:write(string.format("ts=%d loop=%d pid=lua\n", now, M.loop_count))
        f:close()
      end
    end
  end)

  -- 快速检查（每 10 轮）
  if M.loop_count % M.PULSE_FAST == 0 then
    -- 内存趋势
    local mem = check_memory_trend()
    if mem == "exit" then
      proactive_exit("memory_critical")
      return
    end

    -- 热降频
    local thermal = check_thermal()
    if thermal == "slow" then
      M._degraded = true
    end
  end

  -- 中等检查（每 100 轮）
  if M.loop_count % M.PULSE_MEDIUM == 0 then
    -- 磁盘
    local disk = check_disk()
    if disk == "critical" then
      proactive_exit("disk_full")
      return
    end

    -- 文件描述符
    local fd = check_fd_leak()
    if fd == "exit" then
      proactive_exit("fd_leak")
      return
    end

    -- 计时器漂移
    check_timer_drift()

    -- 网络
    check_network()
  end

  -- 深度检查（每 1000 轮）
  if M.loop_count % M.PULSE_DEEP == 0 then
    -- 游戏存活
    check_game_health()

    -- 电量
    check_power()

    -- MemoryGuard 三级保护
    if _G.MemoryGuard and type(_G.MemoryGuard.check) == "function" then
      pcall(_G.MemoryGuard.check)
    end

    -- 强制 GC
    collectgarbage("collect")

    -- 清理 IPC 临时文件
    pcall(function()
      os.execute("find '" .. var_dir() .. "' -name '.ziyan_*.tmp.*' -mmin +5 -delete 2>/dev/null")
    end)

    -- 写入健康心跳
    write_health_log("deep_check", string.format("rss=%d status=%s", get_rss_mb(), M.health_status))
  end

  -- 预防性重启（每 10000 轮）
  if M.loop_count % M.PULSE_REBOOT == 0 then
    local rss = get_rss_mb()
    if rss > 100 then
      proactive_exit("proactive_restart_rss=" .. tostring(rss))
    else
      -- 即使 RSS 正常，也做一次深度清理
      collectgarbage("collect")
      if type(_G.keepScreen) == "function" then pcall(_G.keepScreen, false) end
      write_health_log("proactive_cleanup", string.format("rss=%d", rss))
    end
  end

  -- 反作弊随机暂停
  local pause_ms = check_anti_pattern()
  if pause_ms > 0 and type(_G.mSleep) == "function" then
    -- 不在这里 sleep，避免递归；标记下次循环使用
    M._pending_anti_pause = pause_ms
  end
end

---------------------------------------------------------------------------
-- 记录找色耗时（供 ThermalGuard 使用）
---------------------------------------------------------------------------
function M.record_find_time(ms)
  M._last_find_ms = tonumber(ms) or 0
end

-- 记录找色结果（供冷却期判断）
function M.record_find_result(found)
  if found then
    M._no_find_count = 0
  else
    M._no_find_count = M._no_find_count + 1
  end
end

-- 记录循环耗时（供 TimerDrift 使用）
function M.record_cycle_time(ms)
  M._drift_expected_elapsed = M._drift_expected_elapsed + (tonumber(ms) or 0)
end

---------------------------------------------------------------------------
-- 安装：Hook toast + 初始化
---------------------------------------------------------------------------
function M.install()
  M.start_time = os.time()
  M.loop_count = 0
  M.health_status = "ok"
  M._drift_start_wall = os.time()
  M._drift_expected_elapsed = 0

  -- Hook toast 实现智能抑制
  if type(_G.toast) == "function" and not _G.__ZIYAN_TOAST_HOOKED then
    _original_toast = _G.toast
    _G.toast = smart_toast
    _G.__ZIYAN_TOAST_HOOKED = true
  end

  -- Hook findMultiColorInRegionFuzzy 记录耗时
  if type(_G.findMultiColorInRegionFuzzy) == "function" and not _G.__ZIYAN_FIND_HOOKED then
    local _orig_find = _G.findMultiColorInRegionFuzzy
    _G.findMultiColorInRegionFuzzy = function(...)
      local t0 = os.clock()
      local x, y = _orig_find(...)
      local elapsed = (os.clock() - t0) * 1000
      M.record_find_time(elapsed)
      M.record_find_result(x ~= nil and x ~= -1)
      return x, y
    end
    _G.__ZIYAN_FIND_HOOKED = true
  end

  _G.HealthMonitor = M
  _G.__ZIYAN_HEALTH_MONITOR = M.version

  write_health_log("init", "HealthMonitor started")
  return M
end

-- 获取健康摘要
function M.summary()
  return {
    ts = os.time(),
    loop = M.loop_count,
    rss = get_rss_mb(),
    status = M.health_status,
    uptime_sec = os.time() - M.start_time,
    find_ms = M._last_find_ms,
    no_find = M._no_find_count,
    cycle_ms = M._cycle_ms,
    degraded = M._degraded,
    net_offline = M._net_offline_mode,
    fd_count = get_fd_count(),
    disk_pct = get_disk_usage_pct(),
    battery = get_battery_pct(),
    charging = is_charging(),
  }
end

return M