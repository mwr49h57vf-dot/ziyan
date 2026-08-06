--[[ 文件 IO：本地轻量实现 + 与 py_cv File* 对齐 ]]
local M = {}

local function defined(n) return type(_G[n]) == "function" end
local function ensure(name, fn)
  if not defined(name) then _G[name] = fn end
end

local function exists(path)
  if type(path) ~= "string" or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  -- 目录：尝试列出
  local ok, _, code = os.rename(path, path)
  return ok or code == 13
end

function M.install()
  ensure("readFileString", function(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return s
  end)
  ensure("writeFileString", function(path, content)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(content or "")
    f:close()
    return true
  end)
  ensure("delFile", function(path)
    if type(path) ~= "string" or path == "" then return false end
    return os.remove(path) ~= nil
  end)
  ensure("strSplit", function(str, sep)
    local t = {}
    if type(str) ~= "string" then return t end
    sep = sep or ","
    for part in string.gmatch(str, "([^" .. sep .. "]+)") do
      t[#t + 1] = part
    end
    return t
  end)

  -- 若 py_cv 尚未安装 File*，提供本地兜底（纯 Lua，不依赖第三方）
  ensure("FileExists", exists)
  ensure("FileCreate", function(path, content, is_dir)
    if type(path) ~= "string" or path == "" then return false end
    if is_dir then
      return os.execute(string.format('mkdir -p "%s"', path)) == 0
    end
    local f = io.open(path, "wb")
    if not f then
      local dir = path:match("(.+)/[^/]+$")
      if dir then os.execute(string.format('mkdir -p "%s"', dir)) end
      f = io.open(path, "wb")
    end
    if not f then return false end
    f:write(content or "")
    f:close()
    return true
  end)
  ensure("FileCopy", function(src, dst)
    if not exists(src) then return false end
    return os.execute(string.format('cp -R "%s" "%s"', src, dst)) == 0
  end)
  ensure("FileDelete", function(path)
    if not exists(path) then return false end
    return os.execute(string.format('rm -rf "%s"', path)) == 0
  end)
  ensure("FileMove", function(src, dst)
    if not exists(src) then return false end
    return os.execute(string.format('mv "%s" "%s"', src, dst)) == 0
  end)
  ensure("FileList", function(path, recursive)
    if type(path) ~= "string" or path == "" then return {} end
    local cmd
    if recursive then
      cmd = string.format('find "%s" -mindepth 1 -print 2>/dev/null', path)
    else
      cmd = string.format('ls -1 "%s" 2>/dev/null', path)
    end
    local p = io.popen(cmd)
    if not p then return {} end
    local t = {}
    for line in p:lines() do
      if recursive then
        local rel = line:gsub("^" .. path:gsub("(%W)", "%%%1") .. "/?", "")
        t[#t + 1] = rel
      else
        t[#t + 1] = line
      end
    end
    p:close()
    return t
  end)

  return M
end

return M
