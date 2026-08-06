--[[ Zy.Clipboard — 剪贴板读写（经 device/input 全局或 IPC，非 TS）
  iOS 仅走 writePasteboard/readPasteboard/clearPasteboard 自研链。
]]
local M = { name = "Clipboard", version = "1.0.0" }

local function defined(n) return type(_G[n]) == "function" end

--- 写入剪贴板
function M.set(text)
  text = tostring(text or "")
  if defined("writePasteboard") then
    return not not writePasteboard(text)
  end
  if defined("copyText") then
    return not not copyText(text)
  end
  if type(_G.Zy) == "table" and _G.Zy.Input and type(_G.Zy.Input.text) == "function" then
    -- 输入模块无 set；继续失败
  end
  return false, "no_pasteboard_write"
end

--- 读取剪贴板
function M.get()
  if defined("readPasteboard") then
    return readPasteboard() or ""
  end
  if defined("PasteClipboard") then
    return PasteClipboard() or ""
  end
  return ""
end

--- 清空剪贴板
function M.clear()
  if defined("clearPasteboard") then
    return not not clearPasteboard()
  end
  return M.set("")
end

--- 先写剪贴板再粘贴到焦点（需底层 paste 或 inputText）
function M.pasteToFocus()
  local txt = M.get()
  if txt == "" then return false, "empty" end
  if type(_G.Zy) == "table" and _G.Zy.Input and type(_G.Zy.Input.text) == "function" then
    return _G.Zy.Input.text(txt)
  end
  if defined("inputText") then
    return not not inputText(txt)
  end
  return false, "no_paste_api"
end

return M
