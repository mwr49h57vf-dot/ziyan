--[[ Zy.AntiDetect — F7 反越狱特征探测（自研只读探针，非触动）
  设计：扫描常见越狱路径/进程标志，导出风险分；不做注入绕过
  循环阻塞隐患：全量 probe 禁热路径；建议 ≥5s
]]
local M = { name = "AntiDetect", version = "1.0.0" }

local PATHS = {
  "/Applications/Cydia.app",
  "/Applications/Sileo.app",
  "/var/jb",
  "/usr/lib/ziyan",
  "/var/jb/usr/lib/ziyan",
  "/Library/MobileSubstrate/MobileSubstrate.dylib",
  "/var/jb/usr/lib/substitute-inserter.dylib",
}

local function exists(p)
  local f = io.open(p, "r")
  if f then f:close(); return true end
  -- 目录：尝试拼 /.
  f = io.open(p .. "/.", "r")
  if f then f:close(); return true end
  return false
end

function M.probe()
  local hits = {}
  for _, p in ipairs(PATHS) do
    if exists(p) then hits[#hits + 1] = p end
  end
  local score = math.min(1.0, #hits / 4.0)
  return { ok = true, hits = hits, score = score, level = score < 0.25 and "low" or (score < 0.6 and "mid" or "high") }
end

function M.export()
  local r = M.probe()
  local v = _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
  local f = io.open(v .. "/.ziyan_antidetect", "w")
  if not f then return false, "write" end
  f:write(string.format("score=%.2f\nlevel=%s\nhits=%d\n", r.score, r.level, #r.hits))
  f:close()
  return true, r
end

return M
