--[[ Zy.IssueClassifier — 自动问题分类（阶段 7.6.2）
  类别：
    1 fn_bug          函数问题
    2 device_compat   设备兼容问题
    3 coordinate      坐标问题
    4 ocr             OCR问题
    5 vision          图像识别问题
    6 script_logic    脚本逻辑问题
    7 performance     性能问题
]]
local M = {
  name = "IssueClassifier",
  version = "1.0.0",
  model = "IssueTaxonomy",
}

M.CATEGORIES = {
  { id = "fn_bug",        zh = "函数问题",     rank = 1 },
  { id = "device_compat", zh = "设备兼容问题", rank = 2 },
  { id = "coordinate",    zh = "坐标问题",     rank = 3 },
  { id = "ocr",           zh = "OCR问题",      rank = 4 },
  { id = "vision",        zh = "图像识别问题", rank = 5 },
  { id = "script_logic",  zh = "脚本逻辑问题", rank = 6 },
  { id = "performance",   zh = "性能问题",     rank = 7 },
}

local ISSUE_MAP = {
  forbidden_coord = { category = "coordinate", module = "Touch", confidence = 0.95 },
  tap_no_effect   = { category = "coordinate", module = "Touch", confidence = 0.85 },
  ocr_empty       = { category = "ocr", module = "OCR", confidence = 0.9 },
  vision_miss     = { category = "vision", module = "Vision", confidence = 0.88 },
  phase_stuck     = { category = "script_logic", module = "StateMachine", confidence = 0.8 },
  verify_fail     = { category = "script_logic", module = "Verify", confidence = 0.75 },
  timeout         = { category = "performance", module = "Script", confidence = 0.7 },
  crash           = { category = "fn_bug", module = "Script", confidence = 0.65 },
}

local REASON_HINTS = {
  { pat = "rootless|dpi|resolution|iPhone|compat", category = "device_compat", module = "Device", confidence = 0.8 },
  { pat = "ratio|design|coord|物理|forbidden|tap", category = "coordinate", module = "Coordinate", confidence = 0.85 },
  { pat = "ocr|文字|empty", category = "ocr", module = "OCR", confidence = 0.85 },
  { pat = "color|findColor|vision|image", category = "vision", module = "Image", confidence = 0.8 },
  { pat = "phase|stuck|recover|logic", category = "script_logic", module = "Game", confidence = 0.75 },
  { pat = "timeout|slow|perf|elapsed", category = "performance", module = "Script", confidence = 0.75 },
  { pat = "nil|error|crash|undefined", category = "fn_bug", module = "Script", confidence = 0.7 },
}

local function zh_of(cat)
  for _, c in ipairs(M.CATEGORIES) do
    if c.id == cat then return c.zh end
  end
  return cat
end

--- 分类单个 issue
-- @return table { category, category_zh, module, confidence, source, labels }
function M.classify(issue)
  issue = issue or {}
  local t = tostring(issue.type or issue.issue or "")
  local reason = tostring(issue.reason or "")
  local mapped = ISSUE_MAP[t]
  local out = {
    category = "script_logic",
    category_zh = "脚本逻辑问题",
    module = tostring(issue.module or "Script"),
    confidence = 0.5,
    source = "default",
    issue_type = t,
    labels = {},
  }
  if mapped then
    out.category = mapped.category
    out.module = issue.module or mapped.module
    out.confidence = mapped.confidence
    out.source = "issue_type_map"
  else
    local blob = (t .. " " .. reason):lower()
    for _, h in ipairs(REASON_HINTS) do
      if blob:find(h.pat) then
        out.category = h.category
        out.module = issue.module or h.module
        out.confidence = h.confidence
        out.source = "reason_hint"
        break
      end
    end
  end
  -- 设备字段暗示兼容问题
  if issue.device_hint or (tostring(issue.device or ""):find("53") and tostring(issue.os or ""):find("16")) then
    if out.category == "script_logic" and reason:find("size") then
      out.category = "device_compat"
      out.module = "Device"
      out.confidence = math.max(out.confidence, 0.7)
      out.source = "device_hint"
    end
  end
  out.category_zh = zh_of(out.category)
  out.labels = { out.category, out.module, t }
  M._last = out
  return out
end

function M.classifyMany(issues)
  local list = {}
  for _, iss in ipairs(issues or {}) do
    list[#list + 1] = M.classify(iss)
  end
  return list
end

function M.categories()
  return M.CATEGORIES
end

return M
