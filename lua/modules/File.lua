--[[ Zy.File — 文件模块（自研；Media 根仅作者脚本，模块走 var/ZYCV）]]
local M = { name = "File", version = "1.3.0" }

local function defined(n) return type(_G[n]) == "function" end

local function varDir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function shell_ok(fmt, ...)
  local cmd = string.format(fmt, ...)
  local p = io.popen(cmd .. " 2>/dev/null; echo $?")
  if not p then return false end
  local code = p:read("*l") or "1"
  p:close()
  return tostring(code):match("^0") ~= nil
end

function M.read(path)
  if defined("readFileString") then return readFileString(path) end
  local f = io.open(path, "rb")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  return s
end

--- getFile / loadFile 别名（TS 脚本常用名）
function M.getFile(path)
  return M.read(path)
end

function M.loadFile(path)
  return M.read(path)
end

function M.write(path, content)
  if defined("writeFileString") then return writeFileString(path, content) end
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(content or "")
  f:close()
  return true
end

function M.remove(path)
  if defined("delFile") then return delFile(path) end
  return os.remove(path) ~= nil
end

function M.exists(path)
  if defined("FileExists") then return FileExists(path) end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

function M.scriptsDir()
  return _G.ZIYAN_SCRIPTS or "/private/var/mobile/Media/ZiYan"
end

function M.varDir()
  return varDir()
end

function M.zycvDir()
  return _G.ZIYAN_ZYCV or "/private/var/mobile/Media/ZiYan/ZYCV"
end

--- 追加写入
function M.append(path, content)
  path = tostring(path or "")
  if path == "" then return false, "empty_path" end
  local f = io.open(path, "ab")
  if not f then return false, "open_fail" end
  f:write(tostring(content or ""))
  f:close()
  return true
end

--- 创建目录（递归）
function M.mkdir(path)
  path = tostring(path or "")
  if path == "" then return false, "empty_path" end
  if defined("FileCreate") then
    return FileCreate(path, "", true)
  end
  if defined("mkdir") then
    return not not mkdir(path)
  end
  return shell_ok('mkdir -p "%s"', path:gsub('"', ""))
end

--- 列出目录（非递归）
function M.list(path)
  path = tostring(path or "")
  if defined("FileList") then
    return FileList(path, false)
  end
  if defined("getList") then
    return getList(path)
  end
  local p = io.popen(string.format('ls -1 "%s" 2>/dev/null', path:gsub('"', "")))
  if not p then return {} end
  local t = {}
  for line in p:lines() do t[#t + 1] = line end
  p:close()
  return t
end

--- find(nameOrPattern, rootDir) — shell find，结果写入 ZIYAN_VAR 临时列表
function M.find(nameOrPattern, rootDir)
  nameOrPattern = tostring(nameOrPattern or "*")
  rootDir = tostring(rootDir or "/")
  if rootDir == "" then rootDir = "/" end
  local listFile = varDir() .. "/.zy_find_out.txt"
  local cmd = string.format(
    'find "%s" -name "%s" 2>/dev/null | head -500 > "%s"',
    rootDir:gsub('"', ""), nameOrPattern:gsub('"', ""), listFile:gsub('"', ""))
  os.execute(cmd)
  local t = {}
  local f = io.open(listFile, "r")
  if f then
    for line in f:lines() do
      line = (line:gsub("%s+$", ""))
      if line ~= "" then t[#t + 1] = line end
    end
    f:close()
  end
  return t
end

--- 文件大小（字节）；不存在返回 -1
--- 注意：禁止走 getFileSize 兼容桩（易与 File.size 递归 → stack overflow）
function M.size(path)
  path = tostring(path or "")
  if path == "" then return -1 end
  local f = io.open(path, "rb")
  if f then
    local ok, sz = pcall(function()
      local cur = f:seek("cur") or 0
      local n = f:seek("end") or -1
      f:seek("set", cur)
      return n
    end)
    f:close()
    if ok and tonumber(sz) and tonumber(sz) >= 0 then return tonumber(sz) end
  end
  local p = io.popen(string.format('stat -f%%z "%s" 2>/dev/null || stat -c%%s "%s" 2>/dev/null', path:gsub('"', ""), path:gsub('"', "")))
  if not p then return -1 end
  local s = tonumber(p:read("*l") or "-1") or -1
  p:close()
  return s
end

--- 复制文件/目录
function M.copy(src, dst)
  src, dst = tostring(src or ""), tostring(dst or "")
  if src == "" or dst == "" then return false, "empty_path" end
  if defined("FileCopy") then return FileCopy(src, dst) end
  if defined("copyfile") then return not not copyfile(src, dst) end
  return shell_ok('cp -R "%s" "%s"', src:gsub('"', ""), dst:gsub('"', ""))
end

--- 移动/重命名
function M.move(src, dst)
  src, dst = tostring(src or ""), tostring(dst or "")
  if src == "" or dst == "" then return false, "empty_path" end
  if defined("FileMove") then return FileMove(src, dst) end
  if defined("movefile") then return not not movefile(src, dst) end
  return shell_ok('mv "%s" "%s"', src:gsub('"', ""), dst:gsub('"', ""))
end

--- Wave4：zip / unzip（依赖系统 zip/unzip 命令）
function M.zip(src, dst)
  src, dst = tostring(src or ""), tostring(dst or "")
  if src == "" or dst == "" then return false, "empty_path" end
  return shell_ok('zip -r -q "%s" "%s"', dst:gsub('"', ""), src:gsub('"', ""))
end

function M.unzip(src, dst)
  src, dst = tostring(src or ""), tostring(dst or ".")
  if src == "" then return false, "empty_path" end
  return shell_ok('unzip -o -q "%s" -d "%s"', src:gsub('"', ""), dst:gsub('"', ""))
end

return M
