--[[ Zy.Sandbox — F9 脚本沙箱（自研，基于 SafeExecutor 思路）
  设计：pcall 包装用户回调；写崩溃摘要；不替代 SafeExecutor 热路径
  内存风险：仅捕获错误字符串；禁止无限重试无 sleep
]]
local M = { name = "Sandbox", version = "1.0.0" }

local function varDir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

function M.run(fn, label)
  if type(fn) ~= "function" then return false, "not_fn" end
  local ok, err = pcall(fn)
  if ok then return true end
  local v = varDir()
  local f = io.open(v .. "/.ziyan_sandbox_last_err", "w")
  if f then
    f:write(string.format("ts=%d\nlabel=%s\nerr=%s\n", os.time(), tostring(label or ""), tostring(err)))
    f:close()
  end
  return false, err
end

function M.status()
  local v = varDir()
  local f = io.open(v .. "/.ziyan_sandbox_last_err", "r")
  if not f then return { ok = true, last_err = nil } end
  local s = f:read("*a") or ""
  f:close()
  return { ok = true, last_err = s }
end

return M
