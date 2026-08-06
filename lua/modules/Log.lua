--[[ Zy.Log — 日志输出（文档示例统一入口）]]
local M = { name = "Log", version = "1.0.0" }

function M.write(msg, ms)
  msg = tostring(msg or "")
  print(msg)
  if type(toast) == "function" then
    pcall(toast, msg, tonumber(ms) or 1200)
  end
end

--- 对话框（对齐 dialog 思想；有 dialog 则调用，否则 toast）
function M.dialog(msg, timeout_s)
  msg = tostring(msg or "")
  timeout_s = tonumber(timeout_s) or 0
  if type(dialog) == "function" then
    local ok, ret = pcall(dialog, msg, timeout_s)
    if ok then return true, ret end
  end
  M.write(msg, math.max(800, (timeout_s or 0) * 1000))
  return true, nil
end

-- 也允许 Zy.Log("x") 函数式：在 init 里再绑一次
return M
