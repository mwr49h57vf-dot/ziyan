--[[ HotUpdate — 热更新客户端（功能三/四/五）
  链路：check（服务端清单+兼容性） → download → verify(sha256) → install(原子切换)
        → health_check → 失败尝试 rollback，并核对恢复结果

  设计约束（对齐需求）：
    · 兼容性不通过：绝不下载、绝不安装，返回 device_incompatible
    · 下载中断/文件损坏/校验失败：丢弃下载物，旧版本不受影响
    · 安装包保存在版本目录，state 原子提交 current / previous / health
    · 任何失败返回 false, reason（不抛异常，不阻塞业务）

  服务端契约见 DOCS/接口契约_日志服务_v1.md:
    GET /api/hotupdate/check?device_id=&os=&arch=&ziyan=&channel=
    GET /hotupdate/packages/<version>/<file>   (静态下载)
]]
local M = { name = "HotUpdate", version = "1.0.0" }

local SH_PATH = "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH "

-- 状态根目录：优先 ZIYAN_VAR 下的 versions/（可写、跟随 rootful/rootless）
local function var_dir()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

function M.state_root()
  return (_G.ZIYAN_HOTUPDATE_ROOT or (var_dir() .. "/hotupdate"))
end

local function trim(s) return (tostring(s or ""):gsub("%s+$", "")) end

local function read_text(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a"); f:close(); return body
end

local sequence = 0
local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local function exit_code(ok, kind, code)
  if type(ok) == "number" then return ok == 0 and 0 or ok end
  if ok == true then return 0 end
  return tonumber(code) or 1
end
local function unique(path)
  sequence = sequence + 1
  return path .. ".tmp." .. tostring(os.time()) .. "." .. tostring(sequence)
end
local function write_text(path, body)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then
    local a,b,c = os.execute("mkdir -p " .. quote(dir) .. " 2>/dev/null")
    if exit_code(a,b,c) ~= 0 then return false, "mkdir_failed" end
  end
  local tmp = unique(path)
  local f, why = io.open(tmp, "wb")
  if not f then return false, "open_failed:" .. tostring(why) end
  local ok, err = f:write(body)
  local flushed = ok and f:flush()
  local closed = f:close()
  if not ok or not flushed or not closed then
    os.remove(tmp)
    return false, "write_failed:" .. tostring(err)
  end
  local renamed, rename_error = os.rename(tmp, path)
  if not renamed then os.remove(tmp); return false, "commit_failed:" .. tostring(rename_error) end
  return true
end

local function run_capture(cmd)
  local out
  for _, d in ipairs({var_dir(), "/tmp"}) do
    local candidate = unique(d .. "/.zy_hot_out")
    local f = io.open(candidate, "wb")
    if f then f:close(); out = candidate; break end
  end
  if not out then return "", 1 end
  local called, a,b,c = pcall(os.execute, SH_PATH .. "sh -c " .. quote(cmd) .. " > " .. quote(out) .. " 2>&1")
  local body = read_text(out)
  os.remove(out)
  if not called or body == nil then return body or "", 1 end
  return body, exit_code(a,b,c)
end
M.execute = run_capture
local function shell(cmd) return M.execute(cmd) end

local function shell_timeout(cmd, seconds)
  local tmo = math.max(2, tonumber(seconds) or 25)
  local wrapped = "sh -c " .. quote(cmd) .. " & CP=$!; "
    .. "( sleep " .. tmo .. "; pkill -TERM -P $CP 2>/dev/null; kill -TERM $CP 2>/dev/null ) & WP=$!; "
    .. "wait $CP; EC=$?; kill $WP 2>/dev/null; wait $WP 2>/dev/null; exit $EC"
  return shell(wrapped)
end

local function py_exe()
  -- 设备自带 python（rootless 上可能因 dyld/stdlib 不可用 → 仅作最后兜底）
  for _, p in ipairs({
    "/var/jb/usr/lib/ziyan/bin/python3",
    "/usr/lib/ziyan/bin/python3",
  }) do
    local f = io.open(p, "r")
    if f then f:close(); return p end
  end
  return nil
end

local function helper_py()
  local candidates = {}
  local base = _G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua"
  candidates[#candidates + 1] = base .. "/modules/ziyan_device_net.py"
  candidates[#candidates + 1] = "/var/jb/usr/lib/ziyan/lib/lua/modules/ziyan_device_net.py"
  candidates[#candidates + 1] = "/tmp/ziyan_device_net.py"
  for _, p in ipairs(candidates) do
    local f = io.open(p, "r")
    if f then f:close(); return p end
  end
  return nil
end

local function load_http_min()
  -- rootless/embed 主通道：bash /dev/tcp 极简 HTTP（zy_http_min）
  local candidates = {
    (_G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua") .. "/modules/zy_http_min.lua",
    "/var/jb/usr/lib/ziyan/lib/lua/modules/zy_http_min.lua",
    "/usr/lib/ziyan/lib/lua/modules/zy_http_min.lua",
  }
  for _, p in ipairs(candidates) do
    local f = io.open(p, "r")
    if f then
      f:close()
      local ok, mod = pcall(dofile, p)
      if ok and type(mod) == "table" then return mod end
    end
  end
  return nil
end

local function dpkg_env_prefix()
  -- 真机演练（.61）实测：ZiYan 运行时把 /var/jb/usr/lib/ziyan/lib 放在 DYLD 搜索前列，
  -- 该目录里的旧 libreadline 缺少 _rl_set_timeout → dpkg 调起的 bash（postinst 解释器）
  -- 直接 dyld 崩溃 → 包变 half-configured。调 dpkg 前必须把该目录从 DYLD 路径剥掉，
  -- 同时保留 rootless 的 libroot（/cores/binpack/usr/lib/libroot）以维持路径重映射。
  local libroot = io.open("/cores/binpack/usr/lib/libroot", "r")
  local has_libroot = libroot ~= nil
  if libroot then libroot:close() end
  if has_libroot then
    return "DYLD_LIBRARY_PATH=/cores/binpack/usr/lib/libroot "
  end
  return "DYLD_LIBRARY_PATH= "
end

local function shasum(path)
  local out, code = shell_timeout("sha256sum " .. quote(path) .. " 2>/dev/null || shasum -a 256 "
    .. quote(path) .. " 2>/dev/null || openssl dgst -sha256 " .. quote(path) .. " 2>/dev/null", 90)
  if code ~= 0 then return nil end
  local hash = out:match("(%x+)")
  if not hash or #hash ~= 64 then hash = out:match("=%s*(%x+)") end
  return hash and #hash == 64 and hash:lower() or nil
end

-- 极简 JSON 取值（服务端契约为扁平结构，够用且不引依赖）
local function json_get(body, key)
  if type(body) ~= "string" then return nil end
  local v = body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
  if v ~= nil then return v end
  v = body:match('"' .. key .. '"%s*:%s*(%d+)')
  if v ~= nil then return tonumber(v) end
  local b = body:match('"' .. key .. '"%s*:%s*(true)')
  if b then return true end
  b = body:match('"' .. key .. '"%s*:%s*(false)')
  if b then return false end
  return nil
end

---------------------------------------------------------------------------
-- 设备信息
---------------------------------------------------------------------------

function M.device_id()
  local mid = read_text(var_dir() .. "/.ziyan_device_id")
  if mid and #trim(mid) > 0 then return trim(mid) end
  local model = "unknown"
  local dev = _G.Zy and _G.Zy.Device
  pcall(function()
    if type(dev) == "table" and type(dev.profile) == "function" then
      local p = dev.profile()
      if type(p) == "table" then model = tostring(p.model or model) end
    end
  end)
  if model == "unknown" then
    model = trim(shell("sysctl -n hw.model 2>/dev/null"))
    if #model == 0 then
      model = trim(shell("sysctl -n hw.machine 2>/dev/null"))
    end
    if #model == 0 then model = "unknown" end
  end
  local id = model
  pcall(function()
    local out = trim(shell("uname -n 2>/dev/null"))
    if #out > 0 then id = id .. "-" .. out end
  end)
  write_text(var_dir() .. "/.ziyan_device_id", id)
  return id
end

function M.os_version()
  -- iOS 13 无 plutil/PlistBuddy：优先读 runtime scheme 与 SystemVersion.plist 原文
  local body = read_text("/System/Library/CoreServices/SystemVersion.plist")
  if body then
    local v = body:match("<key>ProductVersion</key>%s*<string>([^<]+)</string>")
    if v and #v > 0 then return v end
  end
  local v = trim(shell(
    "plutil -extract ProductVersion raw /System/Library/CoreServices/SystemVersion.plist 2>/dev/null "
    .. "|| /usr/libexec/PlistBuddy -c 'Print :ProductVersion' /System/Library/CoreServices/SystemVersion.plist 2>/dev/null"))
  if #v == 0 then v = "unknown" end
  return v
end

function M.arch()
  -- 与 postinst 同口径但兼容 SSH PATH 缺失：scheme 标记 → /var/jb → dpkg → uname
  local marker = read_text("/var/mobile/Library/Preferences/com.ziyan.ziyan.runtime_scheme")
  if marker then
    local scheme = trim(marker:match("^([^\n]*)") or "")
    if scheme == "rootless" then return "iphoneos-arm64" end
    if scheme == "rootful" then return "iphoneos-arm" end
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then return "iphoneos-arm64" end
  local a = trim(shell("dpkg-query -W -f='${Architecture}' com.ziyan.ziyan 2>/dev/null"))
  if a == "iphoneos-arm64" then return "iphoneos-arm64" end
  if a == "iphoneos-arm" then return "iphoneos-arm" end
  local machine = trim(shell("uname -m 2>/dev/null"))
  if machine == "arm64" then return "iphoneos-arm64" end
  return "iphoneos-arm"
end

function M.ziyan_version()
  local v = trim(shell("dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null"))
  if #v == 0 then
    local body = read_text(var_dir() .. "/.ziyan_version")
    if body then v = trim(body) end
  end
  if #v == 0 then
    local body = read_text("/var/mobile/Library/Preferences/com.ziyan.ziyan.version")
    if body then v = trim(body) end
  end
  if #v == 0 then v = "unknown" end
  return v
end

---------------------------------------------------------------------------
-- 1) 兼容性判断（本地二次校验，服务端之外的最后一道闸）
---------------------------------------------------------------------------

function M.compatible(pkg, env)
  pkg = pkg or {}
  env = env or {}
  local arch = env.arch or M.arch()
  local osv = env.os or M.os_version()
  local zv = env.ziyan or M.ziyan_version()
  if pkg.architecture and #tostring(pkg.architecture) > 0 and pkg.architecture ~= arch then
    return false, "arch_mismatch:" .. tostring(pkg.architecture) .. "!=" .. tostring(arch)
  end
  local function num(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+).?(%d*)")
    if not a then return nil end
    return tonumber(a) * 10000 + tonumber(b or 0) * 100 + tonumber(c ~= "" and c or 0)
  end
  local o = num(osv)
  if pkg.min_os and num(pkg.min_os) and o and o < num(pkg.min_os) then
    return false, "os_too_old:" .. osv .. "<" .. pkg.min_os
  end
  if pkg.max_os and num(pkg.max_os) and o and o > num(pkg.max_os) then
    return false, "os_too_new:" .. osv .. ">" .. pkg.max_os
  end
  if pkg.ziyan_min and #tostring(pkg.ziyan_min) > 0 and zv ~= "unknown" then
    local newer, reason = M.is_newer(tostring(pkg.ziyan_min), tostring(zv))
    if newer then return false, "ziyan_too_old:" .. zv .. "<" .. pkg.ziyan_min end
    if reason ~= "no_update" then return false, reason end
  end
  return true
end

---------------------------------------------------------------------------
-- 2) 检查更新
---------------------------------------------------------------------------

--- @return table|nil info, string|nil reason
--- info = { update=true, version, sha256, url, size } 或 { update=false, reason }
function M.check(base_url, opts)
  opts = type(opts) == "table" and opts or {}
  base_url = base_url or M.server()
  if type(base_url) ~= "string" or #base_url == 0 then
    return nil, "no_server"
  end
  local function urlencode(value)
    return tostring(value):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)
  end
  local query = string.format(
    "%s/api/hotupdate/check?device_id=%s&os=%s&arch=%s&ziyan=%s&channel=%s",
    base_url,
    urlencode(M.device_id()),
    urlencode(M.os_version()), urlencode(M.arch()), urlencode(M.ziyan_version()), urlencode(opts.channel or "stable"))
  local out = ""
  -- 0) 引擎原生 HTTP（App 内运行时最可靠，不依赖系统命令）
  pcall(function()
    local zy = _G.Zy
    if type(out) == "string" and #out == 0 and type(zy) == "table"
        and type(zy.Network) == "table" and type(zy.Network.httpGet) == "function" then
      local ok, body = zy.Network.httpGet(query, 8)
      if ok and type(body) == "string" then out = body end
    end
  end)
  if #out == 0 and type(_G.httpGet) == "function" then
    pcall(function()
      local body = _G.httpGet(query, 8)
      if type(body) == "string" and #body > 0 then out = body end
    end)
  end
  if #out == 0 then
    out = shell(string.format("wget -q -O- --timeout=8 --tries=1 '%s' 2>/dev/null", query))
  end
  if #out == 0 then
    out = shell(string.format("curl -sS -m 8 '%s' 2>/dev/null", query))
  end
  -- 2) bash /dev/tcp（rootless 主通道：.61 实测 python3 因 dyld/stdlib 不可用）
  if #out == 0 or not out:find('"ok"', 1, true) then
    local hm = load_http_min()
    if hm and type(hm.get) == "function" then
      local gok, gbody = hm.get(query, 10)
      if gok and type(gbody) == "string" and #gbody > 0 then out = gbody end
    end
  end
  -- 3) 设备自带 python3（部分设备可用；rootless 上可能不可用，放最后）
  if #out == 0 or not out:find('"ok"', 1, true) then
    local py, hp = py_exe(), helper_py()
    if py and hp then
      local pout = shell(string.format("'%s' '%s' get '%s' 8", py, hp, query))
      if pout and pout:find('"ok"', 1, true) then out = pout end
    end
  end
  if not out:find('"ok"', 1, true) then
    return nil, "bad_response"
  end
  if #out == 0 then
    return nil, "network_unavailable"
  end
  local info = {
    update = json_get(out, "update"),
    version = json_get(out, "version"),
    sha256 = json_get(out, "sha256"),
    url = json_get(out, "url"),
    size = json_get(out, "size"),
    reason = json_get(out, "reason"),
    detail = json_get(out, "detail"),
    architecture = json_get(out, "architecture"),
    min_os = json_get(out, "min_os"),
    max_os = json_get(out, "max_os"),
    ziyan_min = json_get(out, "ziyan_min"),
  }
  if info.reason == "device_incompatible" then
    return info, "device_incompatible"
  end
  if not info.update then
    return info, info.reason or "no_update"
  end
  -- 本地二次兼容性闸（服务端之外）
  local ok, why = M.compatible({
    architecture = info.architecture or opts.architecture,
    min_os = info.min_os or opts.min_os,
    max_os = info.max_os or opts.max_os,
    ziyan_min = info.ziyan_min or opts.ziyan_min,
  }, opts)
  if not ok then
    info.update = false
    return info, "device_incompatible:" .. tostring(why)
  end
  local installed, installed_error = M.installed_state()
  if not installed then return nil, installed_error end
  local newer, comparison = M.is_newer(info.version, installed.version)
  if not newer then info.update = false; return info, comparison end
  return info, nil
end

function M.server()
  if type(_G.ZIYAN_HOTUPDATE_SERVER) == "string" and #_G.ZIYAN_HOTUPDATE_SERVER > 0 then
    return _G.ZIYAN_HOTUPDATE_SERVER
  end
  local cfg = read_text((_G.ZIYAN_ZYCV or "/private/var/mobile/Media/ZiYan/ZYCV") .. "/config/hotupdate_server.txt")
  if cfg and #trim(cfg) > 0 then return trim(cfg) end
  return ""
end

function M.set_server(url)
  _G.ZIYAN_HOTUPDATE_SERVER = url
  local root = _G.ZIYAN_ZYCV or "/private/var/mobile/Media/ZiYan/ZYCV"
  return write_text(root .. "/config/hotupdate_server.txt", tostring(url) .. "\n")
end

---------------------------------------------------------------------------
-- 3) 下载 + 4) 校验
---------------------------------------------------------------------------

function M.download(url, dest)
  if type(url) ~= "string" or #url == 0 then return false, "no_url" end
  dest = dest or (M.state_root() .. "/downloads/pkg.deb")
  local dir = dest:match("^(.*)/[^/]+$")
  if dir then os.execute(string.format("mkdir -p '%s' 2>/dev/null", dir)) end
  os.remove(dest)
  local engine_done = false
  -- 0) 引擎原生下载（若引擎提供 downloadFile/httpGet 二进制写盘能力）
  pcall(function()
    local zy = _G.Zy
    if type(zy) == "table" and type(zy.Network) == "table"
        and type(zy.Network.downloadFile) == "function" then
      local ok = zy.Network.downloadFile(url, dest)
      engine_done = ok and true or false
    end
  end)
  local out = ""
  if not engine_done then
    out = shell(string.format(
      "wget -q -O '%s' --timeout=20 --tries=2 '%s' 2>/dev/null && echo __OK__ "
        .. "|| curl -sS -m 60 -o '%s' '%s' 2>/dev/null",
      dest, url, dest, url))
  end
  local dl_ok = false
  do
    local f = io.open(dest, "r")
    if f then
      local size = f:seek("end")
      f:close()
      dl_ok = size and size > 1024
    end
  end
  if not dl_ok then
    local hm = load_http_min()
    if hm and type(hm.download) == "function" then
      hm.download(url, dest, 180)
      local f = io.open(dest, "r")
      if f then local sz = f:seek("end"); f:close(); dl_ok = sz and sz > 1024 end
    end
  end
  if not dl_ok then
    local py, hp = py_exe(), helper_py()
    if py and hp then
      shell(string.format("'%s' '%s' download '%s' '%s' 120", py, hp, url, dest))
      local f = io.open(dest, "r")
      if f then local sz = f:seek("end"); f:close(); dl_ok = sz and sz > 1024 end
    end
  end
  local f = io.open(dest, "r")
  if not f then return false, "download_failed" end
  local size = f:seek("end"); f:close()
  if size < 1024 then
    os.remove(dest)
    return false, "download_too_small:" .. tostring(size)
  end
  return true, dest
end

function M.verify(path, expect_sha256)
  local f = io.open(path, "r")
  if not f then return false, "file_missing" end
  f:close()
  if type(expect_sha256) == "string" and #expect_sha256 > 0 then
    local got = shasum(path)
    if not got then return false, "no_sha_tool" end
    if got ~= expect_sha256 then
      os.remove(path)
      return false, "checksum_mismatch"
    end
  end
  -- deb 结构校验（ar 魔数 + control）
  local h = io.open(path, "rb")
  local magic = h:read(8); h:close()
  if magic ~= "!<arch>\n" then
    os.remove(path)
    return false, "not_a_deb"
  end
  return true
end

---------------------------------------------------------------------------
-- 5) 安装（版本目录 + 指针原子切换；失败回滚）
---------------------------------------------------------------------------

local function valid_version(version)
  return type(version) == "string" and version:match("^%d[%w%.%+%-%:~]*$") ~= nil
end

local function read_state()
  local state = read_text(M.state_root() .. "/state")
  if not state then return nil end
  local current, previous, health = state:match("^([^\n]*)\n([^\n]*)\n([^\n]*)\n$")
  if not current or not valid_version(current) then return nil, "corrupt_state" end
  return {current=current, previous=previous ~= "" and previous or nil, health=health}
end
function M.current_version()
  local state, err = read_state()
  if err then return nil end
  if state then return state.current end
  local v = read_text(M.state_root() .. "/current")
  return v and trim(v) or nil
end
function M.previous_version()
  local state, err = read_state()
  if err then return nil end
  if state then return state.previous end
  local v = read_text(M.state_root() .. "/previous")
  return v and trim(v) or nil
end
local function commit_state(version, previous)
  return write_text(M.state_root() .. "/state", version .. "\n" .. (previous or "") .. "\nok\n")
end
function M.installed_state()
  local out, code = shell(dpkg_env_prefix() .. "dpkg-query -W -f='${Status}\t${Version}\t${Architecture}' com.ziyan.ziyan 2>/dev/null")
  if code ~= 0 or trim(out) == "" then return nil, "package_query_failed" end
  local status, version, arch = trim(out):match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
  if status ~= "install ok installed" then return nil, "package_not_configured:" .. tostring(status) end
  if not valid_version(version) then return nil, "invalid_installed_version" end
  return {version=version, architecture=arch, status=status}
end
function M.is_newer(target, current)
  if not valid_version(target) or not valid_version(current) then return false, "bad_version" end
  local _, code = shell(dpkg_env_prefix() .. "dpkg --compare-versions " .. quote(target) .. " gt " .. quote(current))
  if code == 0 then return true end
  if code == 1 then return false, "no_update" end
  return false, "version_compare_failed"
end
local function archive_info(path, version)
  local f = io.open(path, "rb")
  if not f then return nil, "package_missing" end
  local magic = f:read(8); f:close()
  if magic ~= "!<arch>\n" then return nil, "not_a_deb" end
  local out, code = shell(dpkg_env_prefix() .. "dpkg-deb -f " .. quote(path) .. " Package && dpkg-deb -f "
    .. quote(path) .. " Version && dpkg-deb -f " .. quote(path) .. " Architecture")
  if code ~= 0 then return nil, "invalid_deb_control" end
  local package, actual, arch = out:match("^([^\n]+)\n([^\n]+)\n([^\n]+)")
  if package ~= "com.ziyan.ziyan" or actual ~= version or arch ~= M.arch() then
    return nil, "deb_metadata_mismatch"
  end
  local _, payload_code = shell(dpkg_env_prefix() .. "dpkg-deb --fsys-tarfile " .. quote(path) .. " > /dev/null")
  if payload_code ~= 0 then return nil, "invalid_deb_payload" end
  local sha = shasum(path)
  if not sha then return nil, "package_hash_unavailable" end
  local recorded_sha = read_text(path .. ".sha256")
  if recorded_sha and trim(recorded_sha) ~= sha then return nil, "archive_hash_mismatch" end
  return {sha256=sha, version=actual, architecture=arch}
end
local function save_archive(source, version)
  local meta, why = archive_info(source, version)
  if not meta then return nil, why end
  local dest = M.state_root() .. "/versions/" .. version .. "/package.deb"
  if source ~= dest then
    local f = io.open(source, "rb")
    if not f then return nil, "package_missing" end
    local dir = dest:match("^(.*)/[^/]+$")
    local a,b,c = os.execute("mkdir -p " .. quote(dir) .. " 2>/dev/null")
    if exit_code(a,b,c) ~= 0 then f:close(); return nil, "archive_mkdir_failed" end
    local tmp = unique(dest)
    local out = io.open(tmp, "wb")
    if not out then f:close(); return nil, "archive_open_failed" end
    local copied_ok = true
    while true do
      local chunk, read_error = f:read(64 * 1024)
      if not chunk then if read_error then copied_ok = false end; break end
      if not out:write(chunk) then copied_ok = false; break end
    end
    local flushed, closed, source_closed = out:flush(), out:close(), f:close()
    if not copied_ok or not flushed or not closed or not source_closed then
      os.remove(tmp); return nil, "archive_write_failed"
    end
    if not os.rename(tmp, dest) then os.remove(tmp); return nil, "archive_commit_failed" end
    local copied = shasum(dest)
    if copied ~= meta.sha256 then return nil, "archive_copy_mismatch" end
  end
  local hash_saved, hash_error = write_text(dest .. ".sha256", meta.sha256 .. "\n")
  if not hash_saved then return nil, "archive_hash_write_failed:" .. tostring(hash_error) end
  return dest
end
function M.health_check(expected)
  local want = expected or M.current_version()
  if not want then return false, "no_current_version" end
  local installed, why = M.installed_state()
  if not installed then return false, why end
  if installed.version ~= want then return false, "version_mismatch:" .. installed.version end
  if installed.architecture ~= M.arch() then return false, "installed_arch_mismatch" end
  return true
end
local function apply_archive(path, version)
  local out, code = shell(dpkg_env_prefix() .. "dpkg -i " .. quote(path) .. " 2>&1")
  if code ~= 0 then return false, "dpkg_exit_" .. tostring(code) .. ":" .. out:sub(1,200) end
  return M.health_check(version)
end
local function fault(reason)
  local ok, why = write_text(M.state_root() .. "/failure", reason .. "\n")
  return reason .. (ok and "" or ";fault_record_failed:" .. tostring(why))
end
function M.install(deb_path, version, opts)
  opts = type(opts) == "table" and opts or {}
  if type(deb_path) ~= "string" then return false, "no_deb" end
  if not valid_version(version) then return false, "bad_version" end
  -- The caller owns the runtime probe appropriate to this device and candidate.
  -- Package metadata alone cannot establish that the new runtime is healthy.
  if type(opts.health_check) ~= "function" then return false, "runtime_health_required" end
  if read_text(M.state_root() .. "/transaction") then return false, "recovery_required" end
  local before, why = M.installed_state()
  if not before then return false, why end
  local newer, comparison = M.is_newer(version, before.version)
  if not newer then return false, comparison end
  local previous = before.version
  local rollback_source = opts.rollback_path or (M.state_root() .. "/versions/" .. previous .. "/package.deb")
  local rollback_path, backup_error = save_archive(rollback_source, previous)
  if not rollback_path then return false, "rollback_package_unavailable:" .. tostring(backup_error) end
  local candidate, candidate_error = save_archive(deb_path, version)
  if not candidate then return false, candidate_error end
  -- Download/check responses may be stale by the time package preparation ends.
  local latest, latest_error = M.installed_state()
  if not latest then return false, latest_error end
  if latest.version ~= before.version then return false, "installed_version_changed" end
  local state, state_error = read_state()
  if state_error then return false, state_error end
  local committed, journal_error = write_text(M.state_root() .. "/transaction", previous .. "\n" .. version .. "\n")
  if not committed then return false, "transaction_write_failed:" .. tostring(journal_error) end
  local ok, reason = apply_archive(candidate, version)
  if ok then
    local called, healthy, detail = pcall(opts.health_check, version)
    ok = called and healthy == true
    if not ok then reason = "runtime_health_failed:" .. tostring(called and detail or healthy) end
  end
  if ok then ok, reason = commit_state(version, previous) end
  if ok then
    local cleared, clear_error = os.remove(M.state_root() .. "/transaction")
    if not cleared then return false, fault("transaction_cleanup_failed:" .. tostring(clear_error)) end
    os.remove(M.state_root() .. "/failure")
    return true
  end
  local recovered, recovery_error = apply_archive(rollback_path, previous)
  if recovered then
    os.remove(M.state_root() .. "/transaction")
    return false, fault(tostring(reason) .. ";rolled_back")
  end
  return false, fault(tostring(reason) .. ";rollback_failed:" .. tostring(recovery_error))
end
function M.rollback()
  local transaction = read_text(M.state_root() .. "/transaction")
  local previous = transaction and transaction:match("^([^\n]+)") or M.previous_version()
  if not valid_version(previous) then return false, "no_previous_version" end
  local path, why = save_archive(M.state_root() .. "/versions/" .. previous .. "/package.deb", previous)
  if not path then return false, "rollback_package_unavailable:" .. tostring(why) end
  local ok, reason = apply_archive(path, previous)
  if not ok then return false, fault("rollback_failed:" .. tostring(reason)) end
  local committed, commit_error = commit_state(previous, nil)
  if not committed then return false, fault("rollback_state_failed:" .. tostring(commit_error)) end
  if transaction then
    local cleared, clear_error = os.remove(M.state_root() .. "/transaction")
    if not cleared then return false, fault("rollback_cleanup_failed:" .. tostring(clear_error)) end
  end
  os.remove(M.state_root() .. "/failure")
  return true
end

--- 高层入口：检查 → 下载 → 校验 → 兼容闸 → 安装 → 健康检查（失败回滚）
function M.run_once(base_url, opts)
  opts = type(opts) == "table" and opts or {}
  base_url = base_url or M.server()
  local info, reason = M.check(base_url, opts)
  if reason == "device_incompatible" or (info and info.reason == "device_incompatible") then
    return false, "device_incompatible", info
  end
  if not info or not info.update then
    return false, reason or "no_update", info
  end
  if opts.dry_run then
    return true, "dry_run", info
  end
  if not opts.verify_only and type(opts.health_check) ~= "function" then
    return false, "runtime_health_required", info
  end
  local url = info.url
  if url and url:sub(1, 1) == "/" and base_url then
    url = base_url .. url
  end
  local ok, path_or_reason = M.download(url, (opts.dest or (M.state_root() .. "/downloads/pkg.deb")))
  if not ok then return false, path_or_reason, info end
  local vok, vwhy = M.verify(path_or_reason, info.sha256)
  if not vok then return false, vwhy, info end
  if opts.verify_only then return true, "verified", info end
  local iok, iwhy = M.install(path_or_reason, info.version, opts)
  if not iok then return false, iwhy, info end
  local hok, hwhy = M.health_check()
  if not hok then
    local rok, rwhy = M.rollback()
    return false, "health_failed:" .. tostring(hwhy) .. (rok and ";rolled_back" or ";rollback_failed:" .. tostring(rwhy)), info
  end
  return true, "updated", info
end

function M.install_module()
  _G.HotUpdate = M
  _G.__ZIYAN_HOTUPDATE = M.version
  os.execute(string.format("mkdir -p '%s/versions' '%s/downloads' 2>/dev/null", M.state_root(), M.state_root()))
  return M
end

_G.HotUpdate = M
if type(_G.Zy) == "table" then _G.Zy.HotUpdate = M end
return M
