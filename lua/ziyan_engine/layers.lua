--[[
  ziyan_engine/layers.lua
  ------------------------------------------------------------
  文档分层运行时索引（自研）。
  用途：脚本侧查询「模块属于哪一层」——分层范式学习自 TS 官方手册
  章节组织结构，不包含/不调用任何触动私有 API。
]]
local M = { name = "layers", version = "1.0.0" }

-- 与 tools/ziyan_doc/ts_chapter_layer_map.json 对齐的 ZiYan 侧分层
local LAYERS = {
  {
    id = "screen_color",
    zh = "屏幕图像 / 找色",
    modules = { "Screen", "Vision", "Image", "Touch" },
    globals = { "getColor", "findMultiColorInRegionFuzzy", "keepScreen", "snapshot" },
  },
  {
    id = "touch_sim",
    zh = "触控模拟",
    modules = { "Touch", "Coordinate" },
    globals = { "tap", "swipe", "longTap" },
  },
  {
    id = "toast_log",
    zh = "Toast / 日志",
    modules = { "Log" },
    globals = { "toast", "notifyMessage" },
  },
  {
    id = "ocr",
    zh = "OCR识别",
    modules = { "OCR", "Vision" },
    globals = {},
  },
  {
    id = "app_proc",
    zh = "应用 / 进程",
    modules = { "App" },
    globals = {},
  },
  {
    id = "file",
    zh = "文件",
    modules = { "File" },
    globals = { "readFileString", "writeFileString", "copyfile", "movefile" },
  },
  {
    id = "string_util",
    zh = "字符串 / 编码",
    modules = { "String", "Clipboard" },
    globals = { "trim", "split", "strSplit", "urlEncode" },
  },
  {
    id = "timer_dialog",
    zh = "定时 / 对话框",
    modules = { "Timer", "Dialog", "UI" },
    globals = { "mSleep", "sleep", "dialogRet", "dialogInput" },
  },
  {
    id = "device_sys",
    zh = "设备系统 / 网络",
    modules = { "Device", "Network", "Input" },
    globals = { "init", "mSleep", "getNetIP", "batteryStatus" },
  },
  {
    id = "script_session",
    zh = "脚本会话 / 状态机",
    modules = { "Script", "Verify", "StateMachine", "Game", "Engine", "Case" },
    globals = {},
  },
  {
    id = "ai_opt",
    zh = "AI / 优化",
    modules = {
      "AI", "Knowledge", "Optimization", "IssueClassifier",
      "OptimizationAdvisor", "OptimizationRollback", "Diagnose",
    },
    globals = {},
  },
}

function M.list()
  local out = {}
  for i, L in ipairs(LAYERS) do
    out[i] = {
      id = L.id,
      zh = L.zh,
      modules = L.modules,
      globals = L.globals,
    }
  end
  return out
end

function M.find_module(mod_name)
  mod_name = tostring(mod_name or "")
  for _, L in ipairs(LAYERS) do
    for _, m in ipairs(L.modules) do
      if m == mod_name then
        return L.id, L.zh
      end
    end
  end
  return nil, nil
end

function M.find_global(fn_name)
  fn_name = tostring(fn_name or "")
  for _, L in ipairs(LAYERS) do
    for _, g in ipairs(L.globals) do
      if g == fn_name then
        return L.id, L.zh
      end
    end
  end
  return nil, nil
end

function M.install(engine)
  engine = engine or {}
  engine.Layers = M
  -- 挂到 Zy 命名空间（若已加载 modules）
  if type(_G.Zy) == "table" then
    _G.Zy.Layers = {
      list = M.list,
      findModule = M.find_module,
      findGlobal = M.find_global,
      version = M.version,
    }
  end
  return true
end

return M
