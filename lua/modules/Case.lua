--[[ Zy.Case — 自动化测试案例库
  记录：应用→版本→设备→系统→分辨率→DPI→截图→识别→步骤→成败
]]
local M = { name = "Case", version = "1.0.0" }

local function media()
  return "/private/var/mobile/Media/ZiYan"
end

local function case_dir()
  local d = media() .. "/cases"
  pcall(function()
    os.execute(string.format('mkdir -p "%s"', d))
  end)
  return d
end

local function case_file()
  return case_dir() .. "/CASE_DB.jsonl"
end

local function esc(s)
  s = tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
  return s
end

function M.record(row)
  row = row or {}
  local Zy = _G.Zy
  local prof = (Zy and Zy.Device and Zy.Device.profile()) or {}
  local line = string.format(
    '{"ts":%d,"bid":"%s","app_ver":"%s","device":"%s","os":"%s","native":"%sx%s","logic":"%sx%s","dpi":%s,'
      .. '"phase":"%s","action":"%s","ok":%s,"reason":"%s","module":"%s","shot":"%s","event":"%s"}\n',
    os.time(),
    esc(row.bid or _G.__ZIYAN_LAST_BID),
    esc(row.app_ver or ""),
    esc(prof.model or row.device or ""),
    esc(prof.os or row.os or ""),
    tostring(prof.native_w or ""), tostring(prof.native_h or ""),
    tostring(prof.logic_w or ""), tostring(prof.logic_h or ""),
    tostring(prof.dpi or 0),
    esc(row.phase or ""),
    esc(row.action or row.label or ""),
    row.ok and "true" or "false",
    esc(row.reason or ""),
    esc(row.module or ""),
    esc(row.shot or ""),
    esc(row.event or "step")
  )
  local f = io.open(case_file(), "a")
  if f then f:write(line); f:close() end
  -- 镜像到 var 便于主机拉取
  pcall(function()
    local var = (Zy and Zy.File and Zy.File.varDir()) or (_G.ZIYAN_VAR or "/usr/lib/ziyan/var")
    local vf = io.open(var .. "/.ziyan_case_db.jsonl", "a")
    if vf then vf:write(line); vf:close() end
  end)
  return line
end

function M.path()
  return case_file()
end

--- 登记测试应用（仅元数据，不含专用流程）
function M.registerApp(meta)
  meta = meta or {}
  meta.event = "register_app"
  meta.ok = true
  return M.record(meta)
end

return M
