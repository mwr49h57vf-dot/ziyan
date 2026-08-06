--[[ Zy.Knowledge — 子砚自动化经验库（阶段 7.5.4）
  保存任务/设备/截图/OCR/规则/成败/优化记录；供 AI / Script 复用。
]]
local M = {
  name = "Knowledge",
  version = "1.1.0",
  model = "AutomationExperienceDB",
}

local function media()
  return "/private/var/mobile/Media/ZiYan"
end

local function kb_dir()
  local d = media() .. "/knowledge"
  pcall(function() os.execute(string.format('mkdir -p "%s"', d)) end)
  return d
end

local function kb_file()
  return kb_dir() .. "/KB.jsonl"
end

local function esc(s)
  return tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function profile()
  local Zy = _G.Zy
  local p = (Zy and Zy.Device and Zy.Device.profile and Zy.Device.profile()) or {}
  local w, h = 0, 0
  if Zy and Zy.Screen and Zy.Screen.size then
    w, h = Zy.Screen.size()
  end
  return {
    model = p.model or "",
    os = p.os or p.system or "",
    dpi = p.dpi or "",
    logic_w = w,
    logic_h = h,
  }
end

--- 写入一条经验
-- entry: task, game, bid, shot, ocr, rules, flow, fail_reason, optimize, ok, phase, path,
--        issue_type, patch, version, metrics, extra
function M.save(entry)
  entry = entry or {}
  local prof = profile()
  local line = string.format(
    '{"ts":%d,"time":"%s","task":"%s","game":"%s","bid":"%s",'
      .. '"device":"%s","os":"%s","res":"%sx%s",'
      .. '"shot":"%s","ocr":"%s","rules":"%s","flow":"%s",'
      .. '"fail_reason":"%s","optimize":"%s","ok":%s,"phase":"%s","path":"%s",'
      .. '"issue_type":"%s","patch":"%s","version":"%s","metrics":"%s","event":"%s"}\n',
    os.time(),
    os.date("%Y-%m-%d %H:%M:%S"),
    esc(entry.task or entry.goal),
    esc(entry.game or entry.bid),
    esc(entry.bid or ""),
    esc(prof.model),
    esc(prof.os),
    tostring(prof.logic_w), tostring(prof.logic_h),
    esc(entry.shot or ""),
    esc(entry.ocr or ""),
    esc(entry.rules or entry.funcs or ""),
    esc(entry.flow or ""),
    esc(entry.fail_reason or entry.reason or ""),
    esc(entry.optimize or ""),
    entry.ok and "true" or "false",
    esc(entry.phase or ""),
    esc(entry.path or ""),
    esc(entry.issue_type or ""),
    esc(entry.patch or ""),
    esc(entry.version or ""),
    esc(entry.metrics or entry.metrics_summary or ""),
    esc(entry.event or "kb_save")
  )
  local f = io.open(kb_file(), "a")
  if f then f:write(line); f:close() end
  pcall(function()
    local Zy = _G.Zy
    local var = (Zy and Zy.File and Zy.File.varDir()) or (_G.ZIYAN_VAR or "/usr/lib/ziyan/var")
    local vf = io.open(var .. "/.ziyan_kb.jsonl", "a")
    if vf then vf:write(line); vf:close() end
  end)
  return line
end

function M.path()
  return kb_file()
end

--- 按任务名关键词检索最近匹配行（简单文本扫）
function M.query(keyword, limit)
  keyword = tostring(keyword or "")
  limit = tonumber(limit) or 5
  local f = io.open(kb_file(), "r")
  if not f then return {} end
  local hits = {}
  for line in f:lines() do
    if keyword == "" or line:find(keyword, 1, true) then
      hits[#hits + 1] = line
    end
  end
  f:close()
  local out = {}
  for i = math.max(1, #hits - limit + 1), #hits do
    out[#out + 1] = hits[i]
  end
  return out
end

function M.recordSuccess(entry)
  entry = entry or {}
  entry.ok = true
  entry.event = entry.event or "success"
  return M.save(entry)
end

function M.recordFailure(entry)
  entry = entry or {}
  entry.ok = false
  entry.event = entry.event or "failure"
  return M.save(entry)
end

return M
