--[[ OfflineQueue — 服务器不可用时的持久日志队列（功能二）
  设计（对齐需求「服务器关闭时日志不能丢」）：
    · 日志产生即入队（落盘），网络/服务器不可用不影响业务
    · 队列持久化：ZYCV/res/错误报告/.upload_spool/<event_id>/ 下
        report.json（副本） + state.json（attempts/next_retry/状态）
    · 每个文件与事件都有唯一 ID（event_id），重复上传由服务端幂等去重
    · 指数退避：base 30s，翻倍到上限 1h；达到 max_attempts（默认 999）才标 failed
    · App 退出/崩溃/设备重启：状态全在磁盘，重启后 flush 自动续传
    · 服务器恢复：flush 成功即把该事件移入已发送集合，原报告保留（3 天保留期管理）

  对外接口：
    M.enqueue(event_id, report_path)   → true/false （入队副本）
    M.flush(opts)                      → stats{table}  （尝试上传所有到期项）
    M.pending_count()                  → 待上传事件数
    M.stats()                          → 队列统计
    M.install()

  上传通道：优先 Zy.Network.httpPost；退化 curl（同 Network.lua 兜底策略）。
]]

local M = { name = "OfflineQueue", version = "1.0.0" }

-- rootless 设备（.61）的 mkdir/ls/rm 只在 /var/jb/usr/bin —— shell 调用必须自带 PATH
local SH_PATH = "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH "


---------------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------------
M.BASE_RETRY_SEC = 30      -- 首次退避
M.MAX_RETRY_SEC  = 3600    -- 退避上限
M.MAX_ATTEMPTS   = 999     -- 超过才算 failed（长时间服务器关闭不放弃）
M.BATCH          = 8       -- 每次 flush 最多处理条数

-- 默认上报地址：本机局域网/公网可被 --root 或设备配置覆盖
-- 配置来源优先级：_G.ZIYAN_LOG_SERVER > ZYCV/config/log_server.txt > 默认值
M.DEFAULT_SERVER = "http://192.168.31.2:18091"

---------------------------------------------------------------------------
-- 小工具
---------------------------------------------------------------------------
--- 统一命令执行（rootless 的 io.popen 因 /bin/sh 缺失必死；os.execute 在 embed 被
--- ziyan_ios_system 覆盖，/var/jb/bin/sh 优先 → rootless 可用）。命令一律重定向读回。
local var_dir  -- 前向声明：run_capture 依赖它（定义见路径解析区）

local function run_capture(cmd)
  local out = nil
  for _, d in ipairs({ var_dir(), "/tmp",
      (_G.ZIYAN_ZYCV and (_G.ZIYAN_ZYCV .. "/tmp")) or nil,
      _G.ZIYAN_ZYCV }) do
    if d and not out then
      local f = io.open(d .. "/.zy_exec_probe", "w")
      if f then
        f:close()
        os.remove(d .. "/.zy_exec_probe")
        out = d .. "/.zy_exec_out.txt"
      end
    end
  end
  if not out then return nil end
  pcall(function()
    os.execute("( " .. SH_PATH .. cmd .. " ) > '" .. out .. "' 2>&1")
  end)
  local f = io.open(out, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  os.remove(out)
  return body
end

local function root()
  if type(_G.ZIYAN_ZYCV) == "string" and #_G.ZIYAN_ZYCV > 0 then
    return _G.ZIYAN_ZYCV
  end
  local p = "/private/var/mobile/Media/ZiYan/ZYCV"
  if io.open(p .. "/res", "r") then return p end
  local legacy = "/var/mobile/Media/ZiYan/ZYCV"
  if io.open(legacy .. "/res", "r") then return legacy end
  return p
end

var_dir = function()
  return _G.ZIYAN_VAR or "/usr/lib/ziyan/var"
end

local function trim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end

local function read_text(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

local function write_text(path, body)
  local made, reservation = pcall(os.tmpname)
  if not made then return false, "temp_name_failed" end
  local tmp = path .. "." .. reservation:match("[^/\\]+$") .. ".tmp"
  local ok, result, err = pcall(function()
    local f, open_error = io.open(tmp, "wb")
    if not f then return false, open_error end
    local wrote, write_error = f:write(body)
    local closed, close_error = f:close()
    if not wrote or not closed then return false, write_error or close_error end
    local renamed, rename_error = os.rename(tmp, path)
    return renamed and true or false, rename_error
  end)
  os.remove(reservation)
  os.remove(tmp)
  if not ok then return false, tostring(result) end
  return result, err
end

local function valid_event_id(id)
  return type(id) == "string" and #id <= 200 and id:match("^zye_[%w_%-]+$") ~= nil
end

local function copy_file(src, dst)
  local body = read_text(src)
  if not body then return false end
  return write_text(dst, body)
end

local function mkdir_p(path)
  run_capture(string.format("mkdir -p '%s'", path))
  local probe = io.open(path .. "/.probe", "w")
  if probe then
    probe:close()
    os.remove(path .. "/.probe")
    return true
  end
  return false
end

local function shell(cmd)
  local body = run_capture(cmd .. "; echo \"__rc=$?\"")
  if not body then return "", -1 end
  local rc = tonumber(body:match("__rc=(%d+)%s*$") or "")
  body = body:gsub("__rc=%d+%s*$", "")
  return body, rc or -1
end

local function list_dir(path)
  local names = {}
  local listing = run_capture(string.format("ls -1 '%s'", path))
  if listing then
    for name in listing:gmatch("[^\n]+") do names[#names + 1] = name end
  end
  return names
end

---------------------------------------------------------------------------
-- 路径与配置
---------------------------------------------------------------------------

function M.report_dir()
  return root() .. "/res/错误报告"
end

function M.spool_dir()
  return M.report_dir() .. "/.upload_spool"
end

function M.server_url()
  if type(_G.ZIYAN_LOG_SERVER) == "string" and #_G.ZIYAN_LOG_SERVER > 0 then
    return _G.ZIYAN_LOG_SERVER
  end
  local cfg = read_text(root() .. "/config/log_server.txt")
  if cfg then
    local url = trim(cfg:match("^([^\n]*)") or "")
    if #url > 0 then return url end
  end
  return M.DEFAULT_SERVER
end

function M.set_server(url)
  if type(url) ~= "string" or #url == 0 then return false end
  _G.ZIYAN_LOG_SERVER = url
  return write_text(root() .. "/config/log_server.txt", url .. "\n")
end

---------------------------------------------------------------------------
-- 状态文件
---------------------------------------------------------------------------

local function state_path(event_id)
  return M.spool_dir() .. "/" .. event_id .. "/state.json"
end

local function read_state(event_id)
  local body = read_text(state_path(event_id))
  if not body then return nil end
  local status = body:match('"status":"([^"]*)"')
  if body:match('"event_id":"([^"\\]+)"') ~= event_id
      or (status ~= "pending" and status ~= "sent" and status ~= "failed")
      or not body:match('"attempts":%d+') then return nil end
  local st = {
    event_id = event_id,
    attempts = tonumber(body:match('"attempts":(%d+)')) or 0,
    next_retry = tonumber(body:match('"next_retry":(%d+)')) or 0,
    status = body:match('"status":"([^"]*)"') or "pending",
    last_error = body:match('"last_error":"(.-)"') or "",
    dedup = body:find('"dedup":true') ~= nil,
    sent_at = tonumber(body:match('"sent_at":(%d+)')) or 0,
  }
  return st
end

local function write_state(st)
  local parts = {
    string.format('"event_id":"%s"', tostring(st.event_id)),
    string.format('"attempts":%d', tonumber(st.attempts) or 0),
    string.format('"next_retry":%d', tonumber(st.next_retry) or 0),
    string.format('"status":"%s"', tostring(st.status or "pending")),
    string.format('"last_error":"%s"', tostring(st.last_error or ""):gsub('"', "'"):sub(1, 200)),
  }
  if st.dedup then parts[#parts + 1] = '"dedup":true' end
  if tonumber(st.sent_at) and tonumber(st.sent_at) > 0 then
    parts[#parts + 1] = string.format('"sent_at":%d', tonumber(st.sent_at))
  end
  parts[#parts + 1] = string.format('"updated":%d', os.time())
  return write_text(state_path(st.event_id), "{" .. table.concat(parts, ",") .. "}\n")
end

local function backoff_seconds(attempts)
  local sec = M.BASE_RETRY_SEC
  for _ = 1, math.min(attempts, 12) do
    sec = sec * 2
    if sec >= M.MAX_RETRY_SEC then return M.MAX_RETRY_SEC end
  end
  return math.min(sec, M.MAX_RETRY_SEC)
end

---------------------------------------------------------------------------
-- 入队
---------------------------------------------------------------------------

function M.enqueue(event_id, report_path)
  if not valid_event_id(event_id) then return false, "invalid_event_id" end
  local dir = M.spool_dir() .. "/" .. event_id
  if not mkdir_p(dir) then return false end
  local src = report_path or (M.report_dir() .. "/" .. event_id .. "/report.json")
  local existing = read_text(dir .. "/report.json")
  local incoming = read_text(src)
  if not incoming then return false, "report_unreadable" end
  if existing and existing ~= incoming then return false, "event_conflict" end
  if not existing and not copy_file(src, dir .. "/report.json") then return false, "report_write_failed" end
  local st = read_state(event_id) or { event_id = event_id, attempts = 0, next_retry = 0 }
  st.status = st.status or "pending"
  if st.status == "sent" then st.status = "pending" end
  st.next_retry = 0        -- 新入队立即尝试
  return write_state(st)
end

function M.is_durable(event_id, report_path)
  if not valid_event_id(event_id) or not read_state(event_id) then return false end
  local saved = read_text(M.spool_dir() .. "/" .. event_id .. "/report.json")
  if not saved then return false end
  if report_path then return saved == read_text(report_path) end
  return true
end

local function recover_state(event_id)
  local st = read_state(event_id)
  if st then return st end
  if not read_text(M.spool_dir() .. "/" .. event_id .. "/report.json") then return nil end
  st = {event_id=event_id, attempts=0, next_retry=0, status="pending", last_error="recovered_incomplete_commit"}
  if not write_state(st) then return nil, "recovery_write_failed" end
  return st
end

---------------------------------------------------------------------------
-- 上传
---------------------------------------------------------------------------

local function load_http_min()
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

local function http_post(url, body, timeout, headers)
  local tmo = tonumber(timeout) or 10
  -- 1) 引擎/模块层（App 内运行时最可靠）
  local done, ok, resp = pcall(function()
    local zy = _G.Zy
    if type(zy) == "table" and type(zy.Network) == "table"
        and type(zy.Network.httpPost) == "function" then
      local o, r = zy.Network.httpPost(url, body, tmo, headers)
      return o, r
    end
    return false, nil
  end)
  if done and ok then
    local dedup = type(resp) == "string" and resp:find('"dedup":%s*true') ~= nil
    return true, resp, dedup
  end
  -- 2) 命令行兜底：设备上 curl 可能不存在（.101/.112 实测无 curl），wget 不一定有
  local tmp = var_dir() .. "/.zy_queue_post.json"
  if not write_text(tmp, body) then
    tmp = (_G.ZIYAN_ZYCV or "/tmp") .. "/.zy_queue_post.json"
    if not write_text(tmp, body) then return false, "tmp_write_failed" end
  end
  local function run_http(cmd)
    return run_capture(cmd)
  end
  local output = nil
  -- 2a) curl
  output = run_http(string.format(
    "command -v curl >/dev/null 2>&1 && curl -sS -m %d -X POST -H 'Content-Type: application/json' --data-binary @'%s' -w '__HTTP__%%{http_code}' '%s' 2>/dev/null",
    tmo, tmp, url))
  -- 2b) wget（GNU：body 从文件读）
  if output == nil or output == "" then
    output = run_http(string.format(
      "command -v wget >/dev/null 2>&1 && wget -q -O- --timeout=%d --tries=1 --header='Content-Type: application/json' --post-file='%s' '%s' 2>/dev/null",
      tmo, tmp, url))
  end
  -- 2c) bash /dev/tcp（无 curl/wget/python 的精简 rootless 设备，如 .61）
  if output == nil or output == "" then
    local hm = load_http_min()
    if hm and type(hm.post) == "function" then
      local pok, presp = hm.post(url, body, tmo)
      os.remove(tmp)
      if pok then
        local dedup = type(presp) == "string" and presp:find('"dedup":%s*true') ~= nil
        return true, presp, dedup
      end
      return false, tostring(presp)
    end
  end
  os.remove(tmp)
  if output == nil or output == "" then
    return false, "no_http_client_or_empty_response"
  end
  local code = tonumber(output:match("__HTTP__(%d+)%s*$") or "200") or 200
  local resp = output:gsub("__HTTP__%d+%s*$", "")
  if code < 200 or code >= 300 then
    return false, "http_" .. tostring(code)
  end
  local dedup = resp:find('"dedup":%s*true') ~= nil
  return true, resp, dedup
end

local function upload_one(event_id, st, timeout)
  local dir = M.spool_dir() .. "/" .. event_id
  local body = read_text(dir .. "/report.json")
  if not body then
    st.status = "failed"
    st.last_error = "spool_missing"
    if not write_state(st) then return false, nil, "state_commit_failed" end
    return false
  end
  local url = M.server_url() .. "/api/logs"
  local ok, resp_or_err, dedup = http_post(url, body, timeout, nil)
  st.attempts = (st.attempts or 0) + 1
  if ok then
    st.status = "sent"
    st.last_error = ""
    st.next_retry = 0
    st.sent_at = os.time()
    st.dedup = dedup and true or false
    if not write_state(st) then
      st.status = "pending"
      st.last_error = "state_commit_failed"
      return false, nil, "state_commit_failed"
    end
    return true, dedup
  end
  st.status = "pending"
  st.last_error = tostring(resp_or_err or "unknown")
  if st.attempts >= M.MAX_ATTEMPTS then
    st.status = "failed"
    st.next_retry = 0
  else
    st.next_retry = os.time() + backoff_seconds(st.attempts)
  end
  if not write_state(st) then return false, nil, "state_commit_failed" end
  return false
end

--- 尝试上传所有到期条目。never 阻塞业务：最多 BATCH 条，单条超时默认 8s。
--- @param opts table|nil { force=true 忽略退避, now=os.time(), timeout=8, batch=8 }
--- @return table stats { tried, sent, pending, failed, next_retry_in }
function M.flush(opts)
  opts = type(opts) == "table" and opts or {}
  local now = tonumber(opts.now) or os.time()
  local batch = tonumber(opts.batch) or M.BATCH
  local timeout = tonumber(opts.timeout) or 8
  local stats = { tried = 0, sent = 0, pending = 0, failed = 0, next_retry_in = -1, server = M.server_url() }
  local names = list_dir(M.spool_dir())
  local min_wait = nil
  for _, event_id in ipairs(names) do
    if valid_event_id(event_id) then
      local st, recovery_error = recover_state(event_id)
      if recovery_error then stats.storage_errors = (stats.storage_errors or 0) + 1 end
      if st then
        if st.status == "pending" then
          if stats.tried < batch and (opts.force or (tonumber(st.next_retry) or 0) <= now) then
            stats.tried = stats.tried + 1
            local ok, dedup, storage_error = upload_one(event_id, st, timeout)
            if storage_error then
              stats.storage_errors = (stats.storage_errors or 0) + 1
              stats.last_storage_error = storage_error
            end
            if ok then
              stats.sent = stats.sent + 1
              if dedup then stats.dedup = (stats.dedup or 0) + 1 end
            else
              if st.status == "failed" then stats.failed = stats.failed + 1
              else stats.pending = stats.pending + 1 end
              local wait = (tonumber(st.next_retry) or 0) - now
              if wait >= 0 and (min_wait == nil or wait < min_wait) then min_wait = wait end
            end
          else
            stats.pending = stats.pending + 1
            local wait = (tonumber(st.next_retry) or 0) - now
            if wait >= 0 and (min_wait == nil or wait < min_wait) then min_wait = wait end
          end
        elseif st.status == "failed" then
          stats.failed = stats.failed + 1
        elseif st.status == "sent" then
          stats.sent = stats.sent + 0
        end
      end
    end
  end
  if min_wait then stats.next_retry_in = min_wait end
  write_text(var_dir() .. "/.ziyan_queue_last_flush",
    string.format("ts=%d tried=%d sent=%d pending=%d failed=%d\n",
      now, stats.tried, stats.sent, stats.pending, stats.failed))
  return stats
end

function M.pending_count()
  local n = 0
  for _, event_id in ipairs(list_dir(M.spool_dir())) do
    local st = valid_event_id(event_id) and recover_state(event_id)
    if st and st.status == "pending" then n = n + 1 end
  end
  return n
end

function M.stats()
  local s = { pending = 0, sent = 0, failed = 0, total = 0, server = M.server_url() }
  for _, event_id in ipairs(list_dir(M.spool_dir())) do
    local st = valid_event_id(event_id) and recover_state(event_id)
    if st then
      s.total = s.total + 1
      if st.status == "pending" then s.pending = s.pending + 1
      elseif st.status == "sent" then s.sent = s.sent + 1
      elseif st.status == "failed" then s.failed = s.failed + 1 end
    end
  end
  return s
end

--- 把已发送且超过保留期的 spool 目录清掉（由 ErrorReporter.purge 调用）
function M.cleanup_sent(older_than_sec)
  local cutoff = os.time() - (tonumber(older_than_sec) or 3 * 86400)
  local removed = 0
  for _, event_id in ipairs(list_dir(M.spool_dir())) do
    if valid_event_id(event_id) then
      local st = read_state(event_id)
      if st and st.status == "sent" and (tonumber(st.sent_at) or 0) > 0
          and (tonumber(st.sent_at) or 0) < cutoff then
        local dir = M.spool_dir() .. "/" .. event_id
        pcall(function()
          os.execute(SH_PATH .. string.format("rm -rf '%s' 2>/dev/null", dir))
        end)
        removed = removed + 1
      end
    end
  end
  return removed
end

function M.install()
  _G.OfflineQueue = M
  _G.__ZIYAN_OFFLINE_QUEUE = M.version
  pcall(function() mkdir_p(M.spool_dir()) end)
  return M
end

return M
