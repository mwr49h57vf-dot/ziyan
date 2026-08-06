--[[ Script/Debug/debugger.lua — 调试信息采集（委托 Script.debug）]]
local D = { name = "ScriptDebugger", version = "1.0.0" }

function D.snapshot()
  local Zy = assert(_G.Zy, "Zy required")
  if Zy.Script and Zy.Script.debug then
    return Zy.Script.debug({ snapshot = true })
  end
  return { ok = false, err = "Script.debug missing" }
end

function D.dump(path)
  local info = D.snapshot()
  path = path or (( _G.ZIYAN_VAR or "/usr/lib/ziyan/var") .. "/.ziyan_script_debug.txt")
  local lines = {}
  for k, v in pairs(info or {}) do
    lines[#lines + 1] = tostring(k) .. "=" .. tostring(v)
  end
  local f = io.open(path, "w")
  if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
  return info, path
end

return D
