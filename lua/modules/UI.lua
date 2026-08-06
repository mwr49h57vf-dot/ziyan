--[[ Zy.UI — 运行信息窗口 / 对话框（经 SpringBoard 桥，不调用 TouchSprite）]]
local M = { name = "UI", version = "1.0.0", model = "RunInfoDialog" }

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function write_dialog(action, text)
  local path = var_dir() .. "/.ziyan_ui_dialog"
  local f = io.open(path, "w")
  if not f then return false, "open_fail" end
  f:write(tostring(action or "show") .. "\n")
  if text and text ~= "" then
    f:write(tostring(text))
    if not tostring(text):match("\n$") then f:write("\n") end
  end
  f:close()
  return true, path
end

local Dialog = {
  name = "Dialog",
  version = "1.0.0",
  _text = "",
  _visible = false,
}

--- 显示运行信息窗口
function Dialog.show(text)
  if text ~= nil then Dialog._text = tostring(text) end
  Dialog._visible = true
  return write_dialog("show", Dialog._text)
end

--- 隐藏窗口
function Dialog.hide()
  Dialog._visible = false
  return write_dialog("hide", "")
end

--- 更新正文并刷新显示
function Dialog.update(text)
  if text ~= nil then Dialog._text = tostring(text) end
  Dialog._visible = true
  return write_dialog("update", Dialog._text)
end

--- 仅设置正文（下次 show/update 生效；若已显示则立即刷新）
function Dialog.setText(text)
  Dialog._text = tostring(text or "")
  if Dialog._visible then
    return write_dialog("setText", Dialog._text)
  end
  return true, "cached"
end

function Dialog.getText()
  return Dialog._text
end

function Dialog.isVisible()
  return Dialog._visible and true or false
end

--- 根据当前脚本会话拼装默认运行信息并显示
function Dialog.showRunInfo(extra)
  local Zy = _G.Zy
  local lines = {
    "子砚运行信息",
    "time=" .. tostring(os.date("%H:%M:%S")),
  }
  if Zy and Zy.version then
    lines[#lines + 1] = "modules=" .. tostring(Zy.version)
  end
  if Zy and Zy.Script and Zy.Script.get then
    local bid = Zy.Script.get("bid")
    local phase = nil
    if Zy.Game and Zy.Game.phase then
      local ok, p = pcall(Zy.Game.phase)
      if ok then phase = p end
    end
    if bid then lines[#lines + 1] = "bid=" .. tostring(bid) end
    if phase then lines[#lines + 1] = "phase=" .. tostring(phase) end
  end
  if extra and extra ~= "" then
    lines[#lines + 1] = tostring(extra)
  end
  return Dialog.show(table.concat(lines, "\n"))
end

M.Dialog = Dialog
-- 短路径
M.show = function(...) return Dialog.show(...) end
M.hide = function(...) return Dialog.hide(...) end
M.update = function(...) return Dialog.update(...) end
M.setText = function(...) return Dialog.setText(...) end

--- 功能设计 P0：简易配置面板（文件 JSON；无原生 UIKit 表单时用 Dialog 展示）
local function cfg_path(name)
  local base = "/private/var/mobile/Media/ZiYan/ZYCV/config"
  return base .. "/" .. tostring(name or "ui_config") .. ".json"
end

function M.saveUI(name, tbl)
  tbl = tbl or {}
  local path = cfg_path(name)
  local body
  if defined("jsonEncode") then
    body = jsonEncode(tbl)
  else
    -- 极简：仅扁平 string/number
    local parts = {"{"}
    local first = true
    for k, v in pairs(tbl) do
      if not first then parts[#parts + 1] = "," end
      first = false
      if type(v) == "number" then
        parts[#parts + 1] = string.format("%q:%s", tostring(k), tostring(v))
      else
        parts[#parts + 1] = string.format("%q:%q", tostring(k), tostring(v))
      end
    end
    parts[#parts + 1] = "}"
    body = table.concat(parts)
  end
  local f = io.open(path, "w")
  if not f then return false, path end
  f:write(body or "{}")
  f:close()
  return true, path
end

function M.loadUI(name)
  local path = cfg_path(name)
  local f = io.open(path, "r")
  if not f then return nil, path end
  local body = f:read("*a") or ""
  f:close()
  if defined("jsonDecode") then
    local ok, t = pcall(jsonDecode, body)
    if ok then return t, path end
  end
  return { raw = body }, path
end

function M.showConfig(name, defaults)
  local cur = M.loadUI(name)
  if type(cur) ~= "table" then cur = {} end
  defaults = defaults or {}
  for k, v in pairs(defaults) do
    if cur[k] == nil then cur[k] = v end
  end
  M.saveUI(name, cur)
  local lines = { "子砚配置 " .. tostring(name or "ui_config") }
  for k, v in pairs(cur) do
    if k ~= "raw" then
      lines[#lines + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  Dialog.show(table.concat(lines, "\n"))
  return cur
end

return M
