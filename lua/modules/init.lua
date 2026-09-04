--[[
  子砚函数模块层 ZiYan Modules — 通用自动化引擎
  ------------------------------------------------------------
  核心引擎 → 函数模块 → 脚本开发 → 应用验证
  管道：Device→Screen→Coordinate→Vision→OCR→Touch→Verify→StateMachine
  命名：Zy.Module.fn（稳定）+ Device.fn / 设备.中文（7.2 别名，兼容并存）
]]

local function detect_lualib()
  if type(_G.ZIYAN_LUA) == "string" and #_G.ZIYAN_LUA > 0 then
    return _G.ZIYAN_LUA
  end
  if io.open("/var/jb/usr/lib/ziyan/lib/lua/ziyan_engine/init.lua", "r") then
    return "/var/jb/usr/lib/ziyan/lib/lua"
  end
  return "/usr/lib/ziyan/lib/lua"
end

local LUALIB = detect_lualib()
package.path = table.concat({
  LUALIB .. "/?.lua",
  LUALIB .. "/?/init.lua",
  LUALIB .. "/modules/?.lua",
  LUALIB .. "/modules/?/init.lua",
  package.path,
}, ";")

local names = {
  "Device", "App", "Screen", "Coordinate", "Image", "OCR",
  "Touch", "File", "Network", "Verify", "StateMachine",
  "Game", "Diagnose", "Case", "Engine", "Script", "AI",
  "Config", "Input", "UI", "Knowledge", "Optimization",
  "IssueClassifier", "OptimizationAdvisor", "OptimizationRollback", "Log",
  "LearningObserver", "StabilityAnalyzer",
  "String", "Clipboard", "Timer", "Dialog",
  "Thread", "Widget",
  "TestMatrix", "Chat", "RuleEngine", "Decision",
  "HealthMonitor", "SafeExecutor", "MemoryGuard", "CrashLog",
  "ScriptTimeout", "CacheHealth", "Util", "HttpCtl", "PerfGate",
  "AppDump", "AntiDetect", "Sandbox", "FrameHook", "AutoInject",
}

-- 8-161-59：.ziyan_light → 跳过监控/安全包装（对齐触动轻热路径，禁反作弊抬间隔）
do
  local var = _G.ZIYAN_VAR
  if type(var) ~= "string" or var == "" then
    var = (io.open("/var/jb/usr/lib/ziyan/var", "r") and "/var/jb/usr/lib/ziyan/var")
      or "/usr/lib/ziyan/var"
  end
  local light = io.open(var .. "/.ziyan_light", "r")
  if light then
    light:close()
    local skip = {
      HealthMonitor = true, SafeExecutor = true, MemoryGuard = true,
      LearningObserver = true, StabilityAnalyzer = true, PerfGate = true,
      AntiDetect = true, ScriptTimeout = true,
    }
    local kept = {}
    for _, n in ipairs(names) do
      if not skip[n] then kept[#kept + 1] = n end
    end
    names = kept
    _G.ZIYAN_LIGHT = true
  end
end

local Zy = {
  version = "1.14.0",
  layer = "modules",
  kind = "general_automation_engine",
  pipeline = "Device→Screen→Coordinate→Vision→OCR→Touch→Verify→StateMachine",
  docs = "子砚触控函数说明.html",
  scripts = "scripts/",
  ai = "Zy.AI",
  naming = "1.0.0",
  sdk = "Script+AI+Knowledge+Optimization2",
}

for _, n in ipairs(names) do
  local ok, mod = pcall(require, "modules." .. n)
  if not ok then
    ok, mod = pcall(dofile, LUALIB .. "/modules/" .. n .. ".lua")
  end
  if ok and type(mod) == "table" then
    Zy[n] = mod
  else
    Zy[n] = { name = n, error = tostring(mod) }
  end
end

Zy.Vision = {
  name = "Vision",
  -- 与抓色器一致：findMultiColorInRegionFuzzy(主色, 偏点串, degree, x1,y1,x2,y2) → x,y
  findMultiColorInRegionFuzzy = function(...)
    return Zy.Image.findMultiColorInRegionFuzzy(...)
  end,
  findMultiColor = function(...) return Zy.Image.findMultiColor(...) end,
  findColor = function(...) return Zy.Image.findColor(...) end,
  findImage = function(...) return Zy.Image.find(...) end,
  colorAt = function(...) return Zy.Image.colorAtDesign(...) end,
  ocr = function(...) return Zy.OCR.region(...) end,
  findText = function(...) return Zy.OCR.find(...) end,
  analyze = function(...) return Zy.OCR.analyze(...) end,
}

-- 便捷：Zy.Log(msg) 与 Zy.Log.write(msg)
if type(Zy.Log) == "table" and type(Zy.Log.write) == "function" then
  local log_mod = Zy.Log
  setmetatable(log_mod, {
    __call = function(_, msg, ms) return log_mod.write(msg, ms) end,
  })
end

-- 阶段 7.2：短英文全局 + 中文别名（不破坏 Zy.*）
do
  local ok, naming = pcall(require, "modules._naming")
  if not ok then
    ok, naming = pcall(dofile, LUALIB .. "/modules/_naming.lua")
  end
  if ok and type(naming) == "table" and naming.install then
    naming.install(Zy)
  end
end

-- 文档分层索引 → Zy.Layers.list / findModule（自研 layers.lua）
do
  local ok, layers = pcall(require, "ziyan_engine.layers")
  if not ok then
    ok, layers = pcall(dofile, LUALIB .. "/ziyan_engine/layers.lua")
  end
  if ok and type(layers) == "table" then
    Zy.Layers = {
      list = layers.list,
      findModule = layers.find_module,
      findGlobal = layers.find_global,
      version = layers.version,
    }
  end
end

-- 引擎 compat_registry 可能已写入 Zy.Compat；modules 重建 Zy 表时必须保留
local prev_compat = (type(_G.Zy) == "table" and type(_G.Zy.Compat) == "table") and _G.Zy.Compat or nil
if prev_compat then
  Zy.Compat = prev_compat
end

_G.Zy = Zy
_G.ziyan = Zy
_G.ZiYanModules = Zy
_G.__ZIYAN_MODULES = Zy.version

return Zy
