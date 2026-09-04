-- ZiYan 运行时路径：rootless (/var/jb/usr/lib/ziyan) / rootful (/usr/lib/ziyan)
local M = {}
local SCHEME_MARKER = "/var/mobile/Library/Preferences/com.ziyan.ziyan.runtime_scheme"

local function exists(p)
  local f = io.open(p, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function marked_scheme()
  local f = io.open(SCHEME_MARKER, "r")
  if not f then return nil end
  local s = (f:read("*l") or ""):match("^%s*(.-)%s*$")
  f:close()
  if s == "rootful" or s == "rootless" then
    return s
  end
  return nil
end

function M.root()
  if M._root then
    return M._root
  end
  -- postinst 按实际 deb Architecture 写此 marker。`/var/jb` 在 rootful
  -- 设备也可能存在（残留 rootless 树），因此绝不能仅按目录存在选 IPC 根。
  local scheme = marked_scheme()
  if scheme == "rootless" then
    M._root = "/var/jb/usr/lib/ziyan"
  elseif scheme == "rootful" then
    M._root = "/usr/lib/ziyan"
  elseif exists("/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua")
      or exists("/var/jb/usr/lib/ziyan/lib/lua/ziyan_engine/init.lua")
      or exists("/var/jb/usr/lib/ziyan/bin/lua5.3") then
    M._root = "/var/jb/usr/lib/ziyan"
  elseif exists("/usr/lib/ziyan/lib/lua/ziyan_run.lua")
      or exists("/usr/lib/ziyan/bin/lua5.3") then
    M._root = "/usr/lib/ziyan"
  elseif exists("/var/jb") then
    M._root = "/var/jb/usr/lib/ziyan"
  else
    M._root = "/usr/lib/ziyan"
  end
  return M._root
end

function M.var()
  return M.root() .. "/var"
end

function M.lua()
  return M.root() .. "/lib/lua"
end

function M.bin()
  return M.root() .. "/bin"
end

--- rootless/rootful 可用的 sleep 绝对路径（os.execute 的 PATH 常不含 /var/jb/usr/bin）
function M.sleep_bin()
  if M._sleep then
    return M._sleep
  end
  local cands = {
    M.root() .. "/../bin/sleep", -- unlikely
    "/var/jb/usr/bin/sleep",
    "/var/jb/bin/sleep",
    "/usr/bin/sleep",
    "/bin/sleep",
  }
  for _, p in ipairs(cands) do
    if exists(p) then
      M._sleep = p
      return p
    end
  end
  M._sleep = "sleep"
  return M._sleep
end

function M.engine()
  return M.root() .. "/engine"
end

function M.runtime()
  return M.root() .. "/runtime"
end

function M.scripts()
  return "/private/var/mobile/Media/ZiYan"
end

--- 触动兼容：用户入口脚本目录
function M.user_lua()
  return M.scripts() .. "/lua"
end

function M.config_dir()
  return M.zycv() .. "/config"
end

function M.log_dir()
  return M.zycv() .. "/log"
end

function M.tmp_dir()
  return M.zycv() .. "/tmp"
end

function M.res_dir()
  return M.zycv() .. "/res"
end

--- 用户默认可读写：截图/OCR临时/导出 + config/log/tmp/res
function M.zycv()
  return M.scripts() .. "/ZYCV"
end

function M.ensure_zycv()
  local d = M.zycv()
  local f = io.open(d .. "/.keep", "a")
  if f then
    f:close()
  else
    os.execute(string.format("mkdir -p '%s' 2>/dev/null", d))
    f = io.open(d .. "/.keep", "a")
    if f then f:close() end
  end
  for _, sub in ipairs({ "config", "log", "tmp", "res" }) do
    local sd = d .. "/" .. sub
    local sf = io.open(sd .. "/.keep", "a")
    if sf then
      sf:close()
    else
      os.execute(string.format("mkdir -p '%s' 2>/dev/null", sd))
      sf = io.open(sd .. "/.keep", "a")
      if sf then sf:close() end
    end
  end
  return d
end

--- 把历史写死的 /usr/lib/ziyan/... 映射到当前 root
function M.resolve(path)
  path = tostring(path or "")
  local prefix = "/usr/lib/ziyan"
  if path:sub(1, #prefix) == prefix and M.root() ~= prefix then
    return M.root() .. path:sub(#prefix + 1)
  end
  return path
end

return M
