--[[
  子砚引擎 ZiYan Engine
  ------------------------------------------------------------
  运行时：内置脚本引擎（/usr/lib/ziyan/engine + telib.lua）
  文档参考：
    · 触动 init  https://helpdoc.touchsprite.com/dev_docs/1.html
    · 触动手册 https://helpdoc.touchsprite.com/dev_docs/598.html

  架构：
    control  — 暂停/继续/停止（子砚音量键）
    toast    — 非阻塞提示（透明黑底白字）
    screen   — keepScreen（SB 冻帧）/ snapshot
    touch    — touchDown/Up/Move + tap（短按 ~50–80ms）
    color    — 找色别名（兼容）
    cv       — ScreenBridge 多点找色/找图 + dumpScreen
    py_cv    — OCR / 网络 / 文件（找色由 cv 接管）
    app      — appRun/runApp/closeApp
    device   — unlock / 剪贴板 / 路径
    io_fs    — 文件读写删除
    ts_alias — 常用全局别名
    res_interop — res/ 下 pyCall / pyEval（Lua↔Python JSON IPC）
    game     — 游戏开/关/同步/学习表/自动生成脚本/异常恢复
    coordinate — 设计分辨率/游戏区裁剪（Device→Screen→Coordinate）
    vision   — 视觉门面（OCR/找色多方案，经 Coordinate）
    learning — 运行知识库 / 错误库

  入口：require("ziyan_engine") 或 dofile(.../ziyan_engine/init.lua)
]]

local ZIYAN_LUA = _G.ZIYAN_LUA
if type(ZIYAN_LUA) ~= "string" or ZIYAN_LUA == "" then
  if io.open("/var/jb/usr/lib/ziyan/lib/lua/ziyan_engine/init.lua", "r") then
    ZIYAN_LUA = "/var/jb/usr/lib/ziyan/lib/lua"
  else
    ZIYAN_LUA = "/usr/lib/ziyan/lib/lua"
  end
end
_G.ZIYAN_LUA = ZIYAN_LUA

-- 与 ziyan_run / ObjC ZiYanVarDirectory 对齐，避免各模块各猜 rootful/rootless
if type(_G.ZIYAN_VAR) ~= "string" or _G.ZIYAN_VAR == "" then
  if io.open("/var/jb/usr/lib/ziyan/var", "r")
      or io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    _G.ZIYAN_VAR = "/var/jb/usr/lib/ziyan/var"
    _G.ZIYAN_ROOT = "/var/jb/usr/lib/ziyan"
  else
    _G.ZIYAN_VAR = "/usr/lib/ziyan/var"
    _G.ZIYAN_ROOT = "/usr/lib/ziyan"
  end
end
if type(_G.ZIYAN_ZYCV) ~= "string" or _G.ZIYAN_ZYCV == "" then
  _G.ZIYAN_ZYCV = "/private/var/mobile/Media/ZiYan/ZYCV"
end
if type(_G.ZIYAN_SCRIPTS) ~= "string" or _G.ZIYAN_SCRIPTS == "" then
  _G.ZIYAN_SCRIPTS = "/private/var/mobile/Media/ZiYan"
end

  local M = {
  version = "2.28.5",
  name = "ziyan_engine",
  runtime = "ziyan",
  kind = "general_automation_engine",
  -- 运行时：jb root 下 /usr/lib/ziyan + Media/ZiYan
  docs = {
    scripts = "/private/var/mobile/Media/ZiYan",
    modules = ZIYAN_LUA .. "/modules",
    engine = ZIYAN_LUA .. "/ziyan_engine",
  },
  architecture = "engine→modules→script→app_validation",
}

local ROOT = ZIYAN_LUA .. "/ziyan_engine"

local function load_mod(name)
  local path = ROOT .. "/" .. name .. ".lua"
  local ok, mod = pcall(dofile, path)
  if ok and type(mod) == "table" and type(mod.install) == "function" then
    mod.install(M)
    return true
  end
  return false
end

function M.install()
  local prev = _G.__ZIYAN_ENGINE
  if prev ~= M.version then
    -- 升级时允许重新包装找色/触控
    for k, _ in pairs(_G) do
      if type(k) == "string" and (
          k:match("^__ZIYAN_ORIENT_WRAP_") or
          k:match("^__ZIYAN_PAUSE_WRAP_touch")
        ) then
        _G[k] = nil
      end
    end
  elseif prev == M.version then
    load_mod("control")
    load_mod("toast")
    load_mod("orient")
    load_mod("layers")
    load_mod("compat_registry")
    return M
  end
  local order = {
    "control", "codec", "shm", -- 8-150 ControlShm 双写桥
    "toast", "screen",
    "orient",   -- Home 下/左/右，须在 color/touch 之前
    "coord_diag", -- 找色/触控坐标诊断（R3.1）
    "stability", -- SB/循环稳定性心跳（R4）
    "touch", "color",
    "cv",       -- 原生 ScreenBridge 找色（覆盖 TS 多点）
    "py_cv",    -- OCR/内存等（找色已由 cv 接管）
    "app", "device", -- Device 画像 / Device Model
    "coordinate",   -- 坐标转换（须在 device 之后）
    "screen_sync",  -- 屏幕同步模型
    "vision",       -- 视觉门面
    "learning",     -- 知识库
    "verify",       -- 结果验证模型
    "state_machine",-- 游戏状态机
    "io_fs", "ts_alias",
    "layers",      -- R8.4 文档分层索引
    "compat_registry", -- R8.4 TS 文档函数名一一自研镜像注册
    "res_interop", -- res/ Lua↔Py
    "game",        -- 游戏状态 / 学习 / 自动生成
  }
  for _, name in ipairs(order) do
    load_mod(name)
  end
  _G.__ZIYAN_ENGINE = M.version
  _G.__ZIYAN_TE_COMPAT = M.version
  _G.ZiYanEngine = M

  -- ★ 稳定性模块（终稿 P0/P1）：HealthMonitor → MemoryGuard/CrashLog → SafeExecutor(最外层 Hook)
  -- 8-161-61：.ziyan_light / ZIYAN_LIGHT 禁 HM/SafeExecutor（.112 假阳性「画面卡死」降频根因）
  pcall(function()
    local var = _G.ZIYAN_VAR or ""
    local light = _G.ZIYAN_LIGHT == true
    if not light and type(var) == "string" and var ~= "" then
      local f = io.open(var .. "/.ziyan_light", "r")
      if f then f:close(); light = true end
    end
    if light then
      _G.ZIYAN_LIGHT = true
      _G.HealthMonitor = nil
      _G.__ZIYAN_SAFE_MSLEEP_ACTIVE = nil
      return
    end
    local mod_path = ZIYAN_LUA .. "/modules"
    local function load_stab(name)
      local p = mod_path .. "/" .. name .. ".lua"
      if not io.open(p, "r") then return end
      local mod = dofile(p)
      if type(mod) == "table" and type(mod.install) == "function" then
        mod.install()
      end
    end
    load_stab("HealthMonitor")
    load_stab("MemoryGuard")
    load_stab("CrashLog")
    load_stab("CacheHealth")
    load_stab("ScriptTimeout")
    -- SafeExecutor 最后：包在 control/HM 之外，用户脚本零修改
    load_stab("SafeExecutor")
  end)

  return M
end

return M.install()
