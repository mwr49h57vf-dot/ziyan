--[[
  子砚脚本预加载（用户脚本顶层之前）
  加载模块化引擎 ziyan_engine（触摸精灵运行时 + 触动精灵 API 别名）
]]

local ZIYAN = "/private/var/mobile/Media/ZiYan"
local function detect_lualib()
  if _G.ZIYAN_LUA and #tostring(_G.ZIYAN_LUA) > 0 then
    return _G.ZIYAN_LUA
  end
  local candidates = {
    "/var/jb/usr/lib/ziyan/lib/lua",
    "/usr/lib/ziyan/lib/lua",
  }
  for _, p in ipairs(candidates) do
    local f = io.open(p .. "/ziyan_engine/init.lua", "r")
    if f then
      f:close()
      return p
    end
  end
  return "/usr/lib/ziyan/lib/lua"
end

local LUALIB = detect_lualib()
local ROOT = LUALIB:gsub("/lib/lua$", "")

-- 仅子砚路径（Media/ZiYan + lua/ + ZYCV/res + runtime lib）
package.path = table.concat({
  ZIYAN .. "/lua/?.lua",
  ZIYAN .. "/lua/?/init.lua",
  ZIYAN .. "/ZYCV/res/?.lua",
  ZIYAN .. "/ZYCV/res/?/init.lua",
  ZIYAN .. "/?.lua",
  ZIYAN .. "/?/init.lua",
  ZIYAN .. "/scripts/?.lua",
  ZIYAN .. "/scripts/?/init.lua",
  LUALIB .. "/?.lua",
  LUALIB .. "/?/init.lua",
  LUALIB .. "/ziyan_engine/?.lua",
  LUALIB .. "/modules/?.lua",
  ROOT .. "/runtime/var/lib/?.lua",
  package.path,
}, ";")

package.cpath = table.concat({
  LUALIB .. "/?.so",
  package.cpath,
}, ";")

-- 优先模块化引擎；失败则兼容旧路径
local ok = pcall(dofile, LUALIB .. "/ziyan_engine/init.lua")
if not ok then
  pcall(dofile, LUALIB .. "/ziyan_te_compat.lua")
end

-- 函数模块层（平台 API：Zy.*）
pcall(dofile, LUALIB .. "/modules/init.lua")

-- 错误自动收集：记录冷启动 / SpringBoard 重启 / 上次异常退出（真实落盘，不依赖网络）
pcall(function()
  local er = _G.ErrorReporter
  if type(er) == "table" and type(er.on_process_start) == "function" then
    er.on_process_start("ziyan_te_boot")
  end
end)

return true
