--[[ Zy.ScreenMirrorDiagnostic — Screen Mirror 循环诊断门面（7.6.3-R2）
  主机：tools/screen_mirror/collect.sh → logs/screen_mirror/
]]
local M = { name = "ScreenMirrorDiagnostic", version = "1.0.0" }

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

function M.pulse(row)
  row = type(row) == "table" and row or {}
  local line = string.format(
    "ts=%d orient=%s sw=%s sh=%s bw=%s bh=%s scale=%s rot=%s vision=%s touch=%s result=%s\n",
    os.time(),
    tostring(row.orientation or ""),
    tostring(row.screenWidth or ""),
    tostring(row.screenHeight or ""),
    tostring(row.bufferWidth or ""),
    tostring(row.bufferHeight or ""),
    tostring(row.scale or ""),
    tostring(row.rotation or ""),
    tostring(row.visionCoordinate or ""),
    tostring(row.touchCoordinate or ""),
    tostring(row.result or "ok")
  )
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_screen_mirror_pulse", "a")
    if not f then return end
    f:write(line)
    f:close()
  end)
  return true
end

return M
