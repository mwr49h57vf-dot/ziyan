--[[
  兼容入口：旧脚本 / 旧 boot 仍 dofile ziyan_te_compat.lua
  实际转到 ziyan_engine 模块化引擎。
]]
local LUALIB = "/usr/lib/ziyan/lib/lua"
local ok, eng = pcall(dofile, LUALIB .. "/ziyan_engine/init.lua")
if not ok then
  -- 开发机相对路径回退
  local here = debug.getinfo(1, "S").source:match("^@(.*/)") or ""
  ok, eng = pcall(dofile, here .. "ziyan_engine/init.lua")
end

local M = {
  version = (type(eng) == "table" and eng.version) or "2.0.0",
  name = "ziyan_te_compat",
  engine = eng,
}

function M.install()
  if type(eng) == "table" and type(eng.install) == "function" then
    return eng.install()
  end
  return false
end

_G.__ZIYAN_TE_COMPAT = M.version
return M
