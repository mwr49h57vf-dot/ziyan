--[[ HotUpdate — 热更新客户端（功能三/四/五）
  链路：check（服务端清单+兼容性） → download → verify(sha256) → install(原子切换)
        → health_check → 失败自动 rollback，旧版本始终可用

  设计约束（对齐需求）：
    · 兼容性不通过：绝不下载、绝不安装，返回 device_incompatible
    · 下载中断/文件损坏/校验失败：丢弃下载物，旧版本不受影响
    · 安装采用版本目录 + current 指针的原子切换，previous 指针保留可回滚
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

local function write_text(path, body)
  local ok = pcall(function()
    local d = path:match("^(.*)/[^/]+$")
    if d then os.execute(string.format("mkdir -p '%s' 2>/dev/null", d)) end
    local f = io.open(path, "w")
    if not f then return end
    f:write(body); f:close()
  end)
  return ok
end

local function run_capture(cmd)
  -- rootless 的 io.popen 走 libc → /bin/sh 缺失必死；os.execute 在 embed 宿主被
  -- ziyan_ios_system 覆盖（/var/jb/bin/sh 优先）→ 必须用 os.execute + 重定向读回
  local out = nil
  for _, d in ipairs({ var_dir(), "/tmp",
      (_G.ZIYAN_ZYCV and (_G.ZIYAN_ZYCV .. "/tmp")) or nil, _G.ZIYAN_ZYCV }) do
    if d and not out then
      local f = io.open(d .. "/.zy_hot_probe", "w")
      if f then
        f:close()
        os.remove(d .. "/.zy_hot_probe")
        out = d .. "/.zy_hot_out.txt"
      end
    end
  end
  if not out then return "" end
  pcall(function()
    -- 注意：Mac 的 sh 是 bash（接受 "( cmd ) > file" 复合命令），但为与 shell_timeout
    -- 保持一致，统一走 sh -c 单命令调用，避免跨平台 shell 语法差异。
    os.execute(SH_PATH .. "sh -c " .. "'" .. cmd:gsub("'", "'\\''") .. "' > '" .. out .. "' 2>&1")
  end)
  local f = io.open(out, "r")
  if not f then return "" end
  local body = f:read("*a")
  f:close()
  os.remove(out)
  return body
end

local function shell(cmd)
  return run_capture(cmd)
end

--- 子命令带硬超时的执行（VM 内不处理信号；内部用 sh 守护进程杀子孙）
local function shell_timeout(cmd, seconds)
  local out = nil
  for _, d in ipairs({ var_dir(), "/tmp",
      (_G.ZIYAN_ZYCV and (_G.ZIYAN_ZYCV .. "/tmp")) or nil, _G.ZIYAN_ZYCV }) do
    if d and not out then
      local f = io.open(d .. "/.zy_hot_probe", "w")
      if f then
        f:close()
        os.remove(d .. "/.zy_hot_probe")
        out = d .. "/.zy_hot_to.txt"
      end
    end
  end
  if not out then return "" end
  local tmo = math.max(2, tonumber(seconds) or 25)
  -- 关键：杀手 sleep 必须后台化（&），否则 shell 等它跑完，超时反而变慢
  local wrapped = string.format(
    "( ( sleep %d; pkill -P $$ 2>/dev/null; kill -9 $$ 2>/dev/null ) & WPID=$!; "
      .. "%s; EC=$?; kill -9 $WPID 2>/dev/null; wait 2>/dev/null; exit $EC )",
    tmo, cmd)
  pcall(function()
    os.execute(SH_PATH .. "sh -c " .. "'" .. wrapped:gsub("'", "'\\''") .. "' > '" .. out .. "' 2>&1")
  end)
  local f = io.open(out, "r")
  if not f then return "" end
  local body = f:read("*a")
  f:close()
  os.remove(out)
  return body
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
  local has_libroot = io.open("/cores/binpack/usr/lib/libroot", "r") ~= nil
  if has_libroot then
    return "DYLD_LIBRARY_PATH=/cores/binpack/usr/lib/libroot "
  end
  return "DYLD_LIBRARY_PATH= "
end

local function shasum(path)
  local out = shell_timeout(string.format(
    "sha256sum '%s' 2>/dev/null || shasum -a 256 '%s' 2>/dev/null "
      .. "|| openssl dgst -sha256 '%s' 2>/dev/null; echo __ZY_DONE__",
    path, path, path), 90)
  if not out:find("__ZY_DONE__", 1, true) then return nil end
  local hash = out:match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+)")
  if hash then return hash end
  local py, hp = py_exe(), helper_py()
  if py and hp then
    out = shell_timeout(string.format("'%s' '%s' sha256 '%s'; echo __ZY_DONE__", py, hp, path), 120)
    if out:find("__ZY_DONE__", 1, true) then
      hash = out:match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+)")
    end
  end
  return hash
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
    local cur = tostring(zv):match("^(%d+%.%d+%.%d+)")
    if cur and cur < tostring(pkg.ziyan_min) then
      return false, "ziyan_too_old:" .. cur .. "<" .. pkg.ziyan_min
    end
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
  local query = string.format(
    "%s/api/hotupdate/check?device_id=%s&os=%s&arch=%s&ziyan=%s&channel=%s",
    base_url,
    _G.ZHotUpdate_urlencode and _G.ZHotUpdate_urlencode(M.device_id()) or M.device_id(),
    M.os_version(), M.arch(), M.ziyan_version(), opts.channel or "stable")
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
  }
  if info.reason == "device_incompatible" then
    return info, "device_incompatible"
  end
  if not info.update then
    return info, info.reason or "no_update"
  end
  -- 本地二次兼容性闸（服务端之外）
  local ok, why = M.compatible({
    architecture = opts.architecture,
    min_os = opts.min_os,
    max_os = opts.max_os,
    ziyan_min = opts.ziyan_min,
  }, opts)
  if not ok and (opts.architecture or opts.min_os or opts.max_os or opts.ziyan_min) then
    return info, "device_incompatible:" .. tostring(why)
  end
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

function M.current_version()
  local v = read_text(M.state_root() .. "/current")
  return v and trim(v) or nil
end

function M.previous_version()
  local v = read_text(M.state_root() .. "/previous")
  return v and trim(v) or nil
end

function M.install(deb_path, version)
  if type(deb_path) ~= "string" then return false, "no_deb" end
  if not version or #tostring(version) == 0 then return false, "no_version" end
  local root = M.state_root()
  local dest_dir = root .. "/versions/" .. tostring(version)
  os.execute(string.format("mkdir -p '%s' 2>/dev/null", dest_dir))
  -- dpkg 安装（真实生效路径）；失败则回滚指针
  local cur = M.current_version()
  local out = shell(string.format("%sdpkg -i '%s' 2>&1", dpkg_env_prefix(), deb_path))
  local ok = out:find("Setting up com.ziyan.ziyan", 1, true) ~= nil
      or out:find("already installed", 1, true) ~= nil
      or out:find("Unpacking com.ziyan.ziyan", 1, true) ~= nil
  if not ok then
    -- 还原上一条安装记录（dpkg 自身失败时旧包仍在，指针不动）
    return false, "install_failed:" .. tostring(out:sub(1, 200))
  end
  os.execute(string.format("cp -f '%s' '%s/package.deb' 2>/dev/null", deb_path, dest_dir))
  if cur and cur ~= version then
    write_text(root .. "/previous", cur .. "\n")
  end
  write_text(root .. "/current", tostring(version) .. "\n")
  write_text(root .. "/health", "pending\n")
  return true
end

function M.health_check()
  local v = M.current_version()
  if not v then return false, "no_current_version" end
  local out = shell("dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null")
  local want = tostring(v):match("^(%S+)")
  if want and #trim(out) > 0 and not tostring(out):find(want:sub(-20), 1, true) then
    return false, "version_mismatch:" .. trim(out)
  end
  write_text(M.state_root() .. "/health", "ok " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
  return true
end

function M.rollback()
  local prev = M.previous_version()
  if not prev then return false, "no_previous_version" end
  local deb = M.state_root() .. "/versions/" .. prev .. "/package.deb"
  local f = io.open(deb, "r")
  if not f then return false, "previous_deb_missing:" .. deb end
  f:close()
  local ok, why = M.install(deb, prev)
  if not ok then return false, "rollback_failed:" .. tostring(why) end
  write_text(M.state_root() .. "/current", prev .. "\n")
  return true
end

--- 高层入口：检查 → 下载 → 校验 → 兼容闸 → 安装 → 健康检查（失败回滚）
function M.run_once(base_url, opts)
  opts = type(opts) == "table" and opts or {}
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
  local url = info.url
  if url and url:sub(1, 1) == "/" and base_url then
    url = base_url .. url
  end
  local ok, path_or_reason = M.download(url, (opts.dest or (M.state_root() .. "/downloads/pkg.deb")))
  if not ok then return false, path_or_reason, info end
  local vok, vwhy = M.verify(path_or_reason, info.sha256)
  if not vok then return false, vwhy, info end
  if opts.verify_only then return true, "verified", info end
  local iok, iwhy = M.install(path_or_reason, info.version)
  if not iok then return false, iwhy, info end
  local hok, hwhy = M.health_check()
  if not hok then
    local rok = M.rollback()
    return false, "health_failed:" .. tostring(hwhy) .. (rok and " (rolled_back)" or " (rollback_failed)"), info
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
