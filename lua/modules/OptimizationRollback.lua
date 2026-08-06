--[[ Zy.OptimizationRollback — 优化前快照与失败回滚（阶段 7.6.2）
  每次 apply 前 snapshot；verify 失败自动 restore。
]]
local M = {
  name = "OptimizationRollback",
  version = "1.0.0",
  model = "OptSnapshotRollback",
}

local function media()
  return "/private/var/mobile/Media/ZiYan"
end

local function var_dir()
  local Zy = _G.Zy
  if Zy and Zy.File and Zy.File.varDir then return Zy.File.varDir() end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then return "/var/jb/usr/lib/ziyan/var" end
  return "/usr/lib/ziyan/var"
end

local function ensure_dir(d)
  pcall(function() os.execute(string.format('mkdir -p "%s"', d)) end)
end

local function esc(s)
  return tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function snap_root()
  local d = media() .. "/opt/snapshots"
  ensure_dir(d)
  return d
end

local function append_jsonl(path, obj)
  local parts = {}
  for k, v in pairs(obj or {}) do
    if type(v) == "boolean" then
      parts[#parts + 1] = string.format('"%s":%s', k, v and "true" or "false")
    elseif type(v) == "number" then
      parts[#parts + 1] = string.format('"%s":%s', k, tostring(v))
    else
      parts[#parts + 1] = string.format('"%s":"%s"', k, esc(v))
    end
  end
  local line = "{" .. table.concat(parts, ",") .. "}\n"
  local f = io.open(path, "a")
  if f then f:write(line); f:close() end
  return line
end

local function read_file(path)
  if not path or path == "" then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a"); f:close()
  return body
end

local function write_file(path, body)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(body or ""); f:close()
  return true
end

--- 优化前快照
-- meta: { path, reason, version, goal, bid, files? }
-- @return snapshot_id, snapshot_dir
function M.snapshot(meta)
  meta = meta or {}
  local id = "snap_" .. tostring(os.time()) .. "_" .. tostring(math.floor((os.clock() or 0) * 1000) % 10000)
  local dir = snap_root() .. "/" .. id
  ensure_dir(dir)
  local files = meta.files or {}
  if meta.path and meta.path ~= "" then
    files[#files + 1] = meta.path
  end
  local saved = {}
  for _, p in ipairs(files) do
    local body = read_file(p)
    if body then
      local base = p:match("([^/]+)$") or ("f_" .. tostring(#saved))
      local out = dir .. "/" .. base
      write_file(out, body)
      saved[#saved + 1] = { src = p, bak = out }
    end
  end
  -- 也保存内联 src
  if meta.src and meta.src ~= "" then
    write_file(dir .. "/inline_script.lua", meta.src)
    saved[#saved + 1] = { src = meta.path or "inline", bak = dir .. "/inline_script.lua" }
  end
  local info = {
    id = id,
    ts = os.time(),
    time = os.date("%Y-%m-%d %H:%M:%S"),
    reason = tostring(meta.reason or ""),
    version = tostring(meta.version or ""),
    goal = tostring(meta.goal or ""),
    bid = tostring(meta.bid or ""),
    path = tostring(meta.path or ""),
    test_result = tostring(meta.test_result or "pre_apply"),
    n_files = #saved,
  }
  local mf = io.open(dir .. "/meta.json", "w")
  if mf then
    mf:write(string.format(
      '{"id":"%s","ts":%d,"reason":"%s","version":"%s","goal":"%s","bid":"%s","path":"%s","n_files":%d}\n',
      esc(id), info.ts, esc(info.reason), esc(info.version), esc(info.goal),
      esc(info.bid), esc(info.path), info.n_files
    ))
    mf:close()
  end
  -- 索引：原路径列表
  local idx = io.open(dir .. "/files.idx", "w")
  if idx then
    for _, s in ipairs(saved) do
      idx:write(s.src .. "\t" .. s.bak .. "\n")
    end
    idx:close()
  end
  append_jsonl(var_dir() .. "/.ziyan_opt_snapshots.jsonl", {
    ts = info.ts, id = id, reason = info.reason, path = info.path,
    version = info.version, event = "snapshot",
  })
  M._last = info
  M._last_files = saved
  return id, dir, info
end

--- 从快照恢复
function M.restore(snapshot_id)
  snapshot_id = tostring(snapshot_id or (M._last and M._last.id) or "")
  if snapshot_id == "" then return false, "no_snapshot" end
  local dir = snap_root() .. "/" .. snapshot_id
  local idx = io.open(dir .. "/files.idx", "r")
  if not idx then return false, "snapshot_missing" end
  local n = 0
  for line in idx:lines() do
    local src, bak = line:match("([^\t]+)\t([^\t]+)")
    if src and bak then
      local body = read_file(bak)
      if body and src ~= "inline" then
        write_file(src, body)
        n = n + 1
      end
    end
  end
  idx:close()
  append_jsonl(var_dir() .. "/.ziyan_opt_snapshots.jsonl", {
    ts = os.time(), id = snapshot_id, restored = n, event = "restore",
  })
  return true, n
end

--- verify 失败时自动回滚
function M.auto_restore_on_fail(snapshot_id, verify_ok)
  if verify_ok then
    append_jsonl(var_dir() .. "/.ziyan_opt_snapshots.jsonl", {
      ts = os.time(), id = tostring(snapshot_id or ""), event = "keep",
    })
    return false, "verify_ok_keep"
  end
  local ok, n = M.restore(snapshot_id)
  return ok, n
end

function M.list()
  local root = snap_root()
  local out = {}
  -- 轻量：读 jsonl 索引
  local f = io.open(var_dir() .. "/.ziyan_opt_snapshots.jsonl", "r")
  if f then
    for line in f:lines() do
      local id = line:match('"id":"([^"]+)"')
      local ev = line:match('"event":"([^"]+)"')
      if id and ev == "snapshot" then
        out[#out + 1] = { id = id, dir = root .. "/" .. id }
      end
    end
    f:close()
  end
  return out
end

function M.last()
  return M._last
end

return M
