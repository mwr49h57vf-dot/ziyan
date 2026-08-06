--[[
  触动精灵常用别名（TSDaemon / 开发手册）
  文档：https://helpdoc.touchsprite.com/dev_docs/598.html
  仅补齐命名差异；不引入 TSTweak / backboardd。
]]
local M = {}

local function defined(n) return type(_G[n]) == "function" end
local function ensure(name, fn)
  if not defined(name) then _G[name] = fn end
end

function M.install()
  -- 触动 pressHomeKey / 部分脚本 home
  ensure("pressHomeKey", function(times)
    times = tonumber(times) or 1
    for _ = 1, times do
      if defined("keyDown") then
        keyDown("HOME")
        if defined("mSleep") then mSleep(50) end
        if defined("keyUp") then keyUp("HOME") end
      end
      if defined("mSleep") then mSleep(200) end
    end
  end)

  -- 触动常见日志
  ensure("sysLog", function(msg)
    if defined("logDebug") then logDebug(tostring(msg)) end
  end)

  -- 触动：unlockDevice 已在 device.lua；这里补 deviceUnlock 反向别名
  if defined("unlockDevice") and not defined("deviceUnlock") then
    function deviceUnlock(pass)
      return unlockDevice(pass)
    end
  end

  -- 触动 copyText ↔ writePasteboard
  if defined("writePasteboard") and not defined("copyText") then
    function copyText(text)
      return writePasteboard(text)
    end
  end

  -- 触动 inputText：无原生则 toast 提示
  ensure("inputText", function(text)
    if defined("writePasteboard") then
      writePasteboard(text)
    end
    return true
  end)

  return M
end

return M
