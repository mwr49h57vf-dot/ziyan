--[[ SafeExecutor — 执行层透明保护（第零层韧性）
  在 lua5.3 解释器层注入保护，对用户脚本完全透明。
  while true 保持真正的无限循环，只做自适应调节。

  核心原则：
    · while true 就是无限循环，不设人工上限
    · 保护不是"限制"，而是"自适应调节"
    · 用户脚本一行不改，执行行为被透明优化

  找色节拍（学触动公开手册思路，自研实现，禁抄私有 API）：
    · keepScreen：同帧内多次找色才快（手册称高分约 50×）
    · mSleep：触动语义为「精确毫秒」——mSleep(500)=500ms，禁止抬间隔
    · 8-161-50：曾用 max(ms, cycle_ms) 把业务 mSleep(500) 抬到 1s/8s，
      导致循环远慢于触动（framecap 日志见 ~30s+ 一拍）；现与触动对齐

  保护机制：
    1. 找色冷却 — 连续未找到只记状态（不再劫持 mSleep）
    2. 内存感知 — >80MB 降频标记（供监控），不改用户 mSleep
    3. Tap 冷却 — 同坐标 1s 内不重复
    4. 卡死检测 — 100 轮截图无变化 → 告警
    5. 错误捕获 — pcall 包装，记录崩溃
]]

local M = { name = "SafeExecutor", version = "1.2.0" }

---------------------------------------------------------------------------
-- 配置（8-161-50：mSleep 与触动毫秒对齐；cycle_ms 仅作状态展示）
---------------------------------------------------------------------------
M.MIN_CYCLE_MS     = 500     -- 状态默认（不再抬用户 mSleep）
M.MAX_CYCLE_MS     = 8000    -- 冷却状态标记用（不再写入 mSleep）
M.TAP_COOLDOWN_MS  = 1000    -- 同坐标点击冷却（ms）
M.RSS_WARN         = 80      -- 内存预警线（MB）
M.RSS_SAFE         = 50      -- 内存安全线（MB）
M.MAX_NO_FIND      = 5       -- 连续未找到 → 进入冷却标记
M.HEALTH_CHECK_INTERVAL = 10 -- 每 N 轮检测健康
M.STALE_CHECK_INTERVAL  = 100 -- 每 N 轮检测卡死

---------------------------------------------------------------------------
-- 运行时状态
---------------------------------------------------------------------------
M.state = {
  loop_count       = 0,
  no_find_count    = 0,
  last_tap_xy      = nil,    -- 上次点击坐标 "x,y"
  last_tap_time    = 0,      -- 上次点击时间（ms）
  cycle_ms         = 1000,   -- 当前动态间隔
  in_cooldown      = false,  -- 是否在冷却期
  degraded         = false,  -- 是否已降级（内存原因）
  last_screenshot_hash = nil, -- 上次截图指纹（用于卡死检测）
  stale_warn_count = 0,      -- 卡死告警计数
  error_count      = 0,      -- 错误计数
  script_start_ts  = 0,      -- 脚本启动时间
}

-- 保存原始函数引用
local _orig_tap = nil
local _orig_mSleep = nil
local _orig_findMulti = nil
local _orig_keepScreen = nil

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

local function get_rss_mb()
  local f = io.open("/proc/self/status", "r")
  if f then
    local body = f:read("*a") or ""
    f:close()
    local vm = body:match("VmRSS:%s*(%d+)")
    if vm then return math.floor(tonumber(vm) / 1024) end
  end
  return 0
end

local function crash_log_path()
  return var_dir() .. "/.ziyan_crash_log.jsonl"
end

local function self_pid()
  local f = io.open("/proc/self/status", "r")
  if f then
    local body = f:read("*a") or ""
    f:close()
    local pid = body:match("^Pid:%s*(%d+)")
    if pid then return pid end
  end
  return "unknown"
end

local function write_crash_log(err_type, detail)
  local line = string.format(
    '{"ts":%d,"loop":%d,"type":%q,"detail":%q,"rss":%d}\n',
    os.time(), M.state.loop_count, tostring(err_type),
    tostring(detail or ""):sub(1, 200), get_rss_mb())
  pcall(function()
    local f = io.open(crash_log_path(), "a")
    if f then f:write(line); f:close() end
  end)
end

--- 错误自动收集桥：把脚本错误落到 ZYCV/res/错误报告（模块缺失时不报错）
local function report_script_error(err)
  pcall(function()
    local er = _G.ErrorReporter
    if type(er) ~= "table" then return end
    local msg = tostring(err or "unknown")
    -- 停止/暂停类信号不是业务错误，不写错误报告
    if msg:find("ziyan_stop", 1, true)
        or msg:find("interrupted", 1, true) then
      return
    end
    if type(er.handle) == "function" then
      local phase = "script"
      if msg:find("ScriptTimeout", 1, true) then phase = "timeout" end
      er.handle(er.current_script(), msg, { phase = phase, module = "SafeExecutor" })
    end
  end)
end

---------------------------------------------------------------------------
-- 自适应健康检查
---------------------------------------------------------------------------
function M._healthCheck()
  -- 1. 内存自适应（lua RSS + 8-149 SB RSS 高水位旗）
  local rss = get_rss_mb()
  local sb_high = false
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_sb_rss_high", "r")
    if f then f:close(); sb_high = true end
  end)
  if rss > M.RSS_WARN or sb_high then
    -- 8-161-95：内存超标 → keep(false)+释屏旗+GC（对照触动停业务不占帧）
    if type(_G.keepScreen) == "function" then
      pcall(_G.keepScreen, false)
    end
    pcall(function()
      local f = io.open(var_dir() .. "/.ziyan_release_screen", "w")
      if f then f:write("1\n"); f:close() end
    end)
    _G.__ZIYAN_OCR_CACHE = nil
    collectgarbage("collect")
    M.state.cycle_ms = math.min(M.state.cycle_ms * 2, M.MAX_CYCLE_MS)
    M.state.degraded = true
  elseif rss < M.RSS_SAFE and M.state.degraded and not sb_high then
    -- 内存恢复安全：恢复频率
    M.state.cycle_ms = math.max(M.state.cycle_ms / 2, M.MIN_CYCLE_MS)
    if M.state.cycle_ms <= M.MIN_CYCLE_MS then
      M.state.degraded = false
    end
  end

  -- 2. 冷却期 / 活跃期 自适应切换
  if M.state.no_find_count > M.MAX_NO_FIND and not M.state.in_cooldown then
    M.state.in_cooldown = true
    M.state.cycle_ms = M.MAX_CYCLE_MS
  elseif M.state.no_find_count == 0 and M.state.in_cooldown then
    M.state.in_cooldown = false
    M.state.cycle_ms = M.MIN_CYCLE_MS
  end

  -- 3. 卡死检测（每 100 轮）
  if M.state.loop_count % M.STALE_CHECK_INTERVAL == 0 then
    M._staleCheck()
  end
end

---------------------------------------------------------------------------
-- 卡死检测
---------------------------------------------------------------------------
function M._staleCheck()
  -- 通过检测截图内容是否长期不变来判断卡死
  -- 简单实现：检测 keepScreen 帧的像素采样
  -- 如果连续 3 次检测（300 轮）无变化，判定卡死
  if type(_G.getColor) ~= "function" then return end

  -- 取屏幕中心和四角共 5 个采样点
  local w, h = 1136, 640
  if type(_G.getScreenSize) == "function" then
    w, h = _G.getScreenSize()
  end
  local samples = {
    { math.floor(w * 0.5), math.floor(h * 0.5) },
    { math.floor(w * 0.1), math.floor(h * 0.1) },
    { math.floor(w * 0.9), math.floor(h * 0.1) },
    { math.floor(w * 0.1), math.floor(h * 0.9) },
    { math.floor(w * 0.9), math.floor(h * 0.9) },
  }

  local hash = ""
  for _, p in ipairs(samples) do
    local c = tonumber(_G.getColor(p[1], p[2])) or 0
    hash = hash .. string.format("%06X", c % 0x1000000)
  end

  if M.state.last_screenshot_hash == hash then
    M.state.stale_warn_count = M.state.stale_warn_count + 1
    if M.state.stale_warn_count >= 3 then
      -- 300 轮画面无变化 → 可能卡死
      write_crash_log("screen_stale", "300 cycles no change")
      M.state.cycle_ms = M.MAX_CYCLE_MS
      M.state.stale_warn_count = 0  -- 重置，避免重复告警
      -- 不停止 while true，可能只是游戏加载
      if type(_G.toast) == "function" then
        pcall(_G.toast, "[Health] 画面可能卡死，已降频", 2000)
      end
    end
  else
    M.state.last_screenshot_hash = hash
    M.state.stale_warn_count = 0
  end
end

---------------------------------------------------------------------------
-- 包装后的 tap：只透传脚本传入的参数
---------------------------------------------------------------------------
local function safe_tap(...)
  if not _orig_tap then return end
  return _orig_tap(...)
end

---------------------------------------------------------------------------
-- 包装后的 mSleep：注入健康检查 + 自适应间隔
---------------------------------------------------------------------------
local function safe_mSleep(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then
    -- 零延迟：只做暂停/停止检查
    if type(_G.__ZIYAN_wait_while_paused) == "function" then
      _G.__ZIYAN_wait_while_paused()
    end
    return
  end

  M.state.loop_count = M.state.loop_count + 1

  -- 每 N 轮健康检查（本层）
  if M.state.loop_count % M.HEALTH_CHECK_INTERVAL == 0 then
    M._healthCheck()
  end

  -- 同步 HealthMonitor + 触发 9 维 pulse（control 在 SAFE_MSLEEP_ACTIVE 时跳过）
  if _G.HealthMonitor then
    _G.HealthMonitor._cycle_ms = M.state.cycle_ms
    _G.HealthMonitor._degraded = M.state.degraded
    if type(_G.HealthMonitor.pulse) == "function" then
      pcall(_G.HealthMonitor.pulse)
    end
  end

  -- 8-161-50/95：用户 mSleep(N) 基准对齐触动；仅 degraded/冷却时软垫 ≤150ms
  -- （禁止抬成 1s/8s；对照 .171 圈间 350–500ms 节流，非忙等）
  local effective_ms = ms
  if ms > 50 then
    if M.state.degraded or M.state.in_cooldown then
      local pad = math.min(150, math.max(0, (tonumber(M.state.cycle_ms) or 0) - ms))
      if pad > 0 and pad < 200 then
        effective_ms = ms + pad
      end
    end
    if _G.HealthMonitor and tonumber(_G.HealthMonitor._pending_anti_pause or 0) > 0 then
      effective_ms = effective_ms + tonumber(_G.HealthMonitor._pending_anti_pause)
      _G.HealthMonitor._pending_anti_pause = 0
    end
  end

  -- 调用原始 mSleep（通常已是 control 包装：暂停/停止检查）
  if _orig_mSleep then
    return _orig_mSleep(effective_ms)
  end
end

---------------------------------------------------------------------------
-- 包装后的 findMultiColorInRegionFuzzy：记录找色结果
---------------------------------------------------------------------------
local function safe_findMulti(...)
  if not _orig_findMulti then return -1, -1 end

  local x, y = _orig_findMulti(...)

  if x and x ~= -1 then
    M.state.no_find_count = 0
    -- 找到了 → 退出冷却期
    if M.state.in_cooldown then
      M.state.in_cooldown = false
      M.state.cycle_ms = M.MIN_CYCLE_MS
    end
  else
    M.state.no_find_count = M.state.no_find_count + 1
    -- 连续未找到 → 进入冷却期
    if M.state.no_find_count > M.MAX_NO_FIND and not M.state.in_cooldown then
      M.state.in_cooldown = true
      M.state.cycle_ms = M.MAX_CYCLE_MS
    end
  end

  return x, y
end

---------------------------------------------------------------------------
-- 包装用户脚本执行
---------------------------------------------------------------------------
function M.wrap(script_fn)
  if type(script_fn) ~= "function" then
    return false, "script_fn is not a function"
  end

  -- 运行标记（异常退出检测）：进程被强杀/崩溃时文件留存，下次启动由
  -- ErrorReporter.on_process_start 读取并记为 abnormal_exit
  pcall(function()
    local er = _G.ErrorReporter
    local script = "unknown"
    if type(er) == "table" and type(er.current_script) == "function" then
      script = tostring(er.current_script())
    end
    local f = io.open(var_dir() .. "/.ziyan_running", "w")
    if f then
      f:write(string.format("%s pid=%s ts=%d\n", script, tostring(self_pid()), os.time()))
      f:close()
    end
  end)

  -- 保存原始函数
  _orig_tap = _G.tap
  _orig_mSleep = _G.mSleep
  _orig_findMulti = _G.findMultiColorInRegionFuzzy
  _orig_keepScreen = _G.keepScreen

  -- 注入保护 Hook
  if type(_orig_tap) == "function" then
    _G.tap = safe_tap
  end
  if type(_orig_mSleep) == "function" then
    _G.mSleep = safe_mSleep
  end
  if type(_orig_findMulti) == "function" then
    _G.findMultiColorInRegionFuzzy = safe_findMulti
  end

  -- 初始化状态
  M.state.loop_count = 0
  M.state.no_find_count = 0
  M.state.cycle_ms = M.MIN_CYCLE_MS
  M.state.in_cooldown = false
  M.state.degraded = false
  M.state.script_start_ts = os.time()
  M.state.stale_warn_count = 0
  M.state.error_count = 0

  -- 执行用户脚本（pcall 捕获崩溃）
  local ok, err = pcall(script_fn)

  -- 恢复 Hook
  M._restoreHooks()

  if not ok then
    M.state.error_count = M.state.error_count + 1
    write_crash_log("script_error", tostring(err))
    report_script_error(err)
    -- 异常退出标记保留（供下次启动归因）；正常结束才清除
    return false, err
  end

  pcall(os.remove, var_dir() .. "/.ziyan_running")

  return true
end

---------------------------------------------------------------------------
-- 恢复被 Hook 的全局函数
---------------------------------------------------------------------------
function M._restoreHooks()
  if _orig_tap then _G.tap = _orig_tap end
  if _orig_mSleep then _G.mSleep = _orig_mSleep end
  if _orig_findMulti then _G.findMultiColorInRegionFuzzy = _orig_findMulti end
  if _orig_keepScreen then _G.keepScreen = _orig_keepScreen end
end

---------------------------------------------------------------------------
-- 获取执行摘要
---------------------------------------------------------------------------
function M.summary()
  return {
    loop = M.state.loop_count,
    no_find = M.state.no_find_count,
    cycle_ms = M.state.cycle_ms,
    in_cooldown = M.state.in_cooldown,
    degraded = M.state.degraded,
    errors = M.state.error_count,
    uptime_sec = os.time() - M.state.script_start_ts,
  }
end

---------------------------------------------------------------------------
-- 激活全局 Hook（用户脚本零修改；须在 control/HM 之后 install）
---------------------------------------------------------------------------
function M.activate()
  if _G.__ZIYAN_SAFE_EXECUTOR_ACTIVE then
    return M
  end
  -- 保存当前全局（可能已被 control / HealthMonitor 包装）
  _orig_tap = _G.tap
  _orig_mSleep = _G.mSleep
  _orig_findMulti = _G.findMultiColorInRegionFuzzy
  _orig_keepScreen = _G.keepScreen

  if type(_orig_tap) == "function" then
    _G.tap = safe_tap
  end
  if type(_orig_mSleep) == "function" then
    _G.mSleep = safe_mSleep
    _G.__ZIYAN_SAFE_MSLEEP_ACTIVE = true
  end
  if type(_orig_findMulti) == "function" then
    _G.findMultiColorInRegionFuzzy = safe_findMulti
  end

  M.state.loop_count = 0
  M.state.no_find_count = 0
  M.state.cycle_ms = M.MIN_CYCLE_MS
  M.state.in_cooldown = false
  M.state.degraded = false
  M.state.script_start_ts = os.time()
  M.state.stale_warn_count = 0
  M.state.error_count = 0
  _G.__ZIYAN_SAFE_EXECUTOR_ACTIVE = true
  _G.__ZIYAN_SAFE_EXECUTOR = M.version
  return M
end

---------------------------------------------------------------------------
-- 安装
---------------------------------------------------------------------------
function M.install()
  _G.SafeExecutor = M
  _G.__ZIYAN_SAFE_EXECUTOR = M.version
  -- 终稿 8.1：透明挂载，不依赖脚本调用 wrap()
  pcall(M.activate)
  return M
end

return M
