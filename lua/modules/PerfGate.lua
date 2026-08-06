--[[ Zy.PerfGate — F8 性能监控门禁导出（自研）
  聚合 color_perf / HealthMonitor / framecap_alive → .ziyan_perf_gate
  循环阻塞隐患：仅读文件，禁止在热路径每帧调用（建议 ≥1s）
]]
local M = { name = "PerfGate", version = "1.0.0" }

local function varDir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function readTrim(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a") or ""
  f:close()
  return (s:gsub("%s+$", ""))
end

function M.snapshot()
  local v = varDir()
  local snap = {
    ts = os.time(),
    find_via = readTrim(v .. "/.ziyan_find_via"),
    color_perf = readTrim(v .. "/.ziyan_color_perf"),
    framecap_alive = readTrim(v .. "/.ziyan_framecap_alive"),
    sb_rss = readTrim(v .. "/.ziyan_sb_rss"),
    hid_perf = readTrim(v .. "/.ziyan_hid_perf"),
  }
  if type(Zy) == "table" and type(Zy.HealthMonitor) == "table" and Zy.HealthMonitor.snapshot then
    local ok, hm = pcall(Zy.HealthMonitor.snapshot)
    if ok then snap.health = hm end
  end
  return snap
end

function M.export()
  local s = M.snapshot()
  local v = varDir()
  local f = io.open(v .. "/.ziyan_perf_gate", "w")
  if not f then return false, "write_fail" end
  f:write(string.format(
    "ts=%s\nfind_via=%s\ncolor_perf=%s\nframecap=%s\nsb_rss=%s\nhid_perf=%s\n",
    tostring(s.ts), tostring(s.find_via or ""), tostring(s.color_perf or ""),
    tostring(s.framecap_alive or ""), tostring(s.sb_rss or ""), tostring(s.hid_perf or "")))
  f:close()
  return true, s
end

return M
