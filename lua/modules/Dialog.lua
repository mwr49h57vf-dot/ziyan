--[[ Zy.Dialog — 对话框门面（诚实实现：无 TS 模态窗时用 toast/UI 桥）
  不调用触动 fwShow* / showUI 私有 API。
]]
local M = { name = "Dialog", version = "1.0.0" }

local function toast_msg(msg, ms)
  msg = tostring(msg or "")
  ms = tonumber(ms) or 2000
  if type(toast) == "function" then
    pcall(toast, msg, ms)
    return true
  end
  if type(_G.Zy) == "table" and _G.Zy.Log and type(_G.Zy.Log.write) == "function" then
    _G.Zy.Log.write(msg, ms)
    return true
  end
  print(msg)
  return true
end

--- 简单提示（对齐 dialog）
function M.alert(msg, timeout_s)
  timeout_s = tonumber(timeout_s) or 0
  local ms = timeout_s > 0 and (timeout_s * 1000) or 2000
  toast_msg(msg, ms)
  return true
end

--- 带按钮对话框：无原生模态时诚实返回 btn_index=0（第一个按钮）
function M.confirm(msg, btn1, btn2, timeout_s)
  btn1 = tostring(btn1 or "确定")
  btn2 = btn2 and tostring(btn2) or nil
  local hint = msg
  if btn2 then
    hint = tostring(msg) .. " [" .. btn1 .. "/" .. btn2 .. "]"
  else
    hint = tostring(msg) .. " [" .. btn1 .. "]"
  end
  toast_msg(hint, (tonumber(timeout_s) or 0) > 0 and timeout_s * 1000 or 2500)
  return 0, btn1
end

--- 参数输入框：当前无阻塞输入 UI，返回 false + 默认值
function M.input(title, default, timeout_s)
  title = tostring(title or "输入")
  default = tostring(default or "")
  toast_msg(title .. " (default=" .. default .. ")", 2000)
  if type(_G.Zy) == "table" and _G.Zy.UI and _G.Zy.UI.Dialog then
    pcall(_G.Zy.UI.Dialog.show, title .. "\n" .. default)
  end
  return false, default, "no_modal_input"
end

--- 对齐 TS dialogRet：idx, btnText
function M.ret(msg, btn1, btn2, timeout_s)
  return M.confirm(msg, btn1, btn2, timeout_s)
end

--- 对齐 TS dialogInput
function M.inputRet(title, default, timeout_s)
  return M.input(title, default, timeout_s)
end

return M
