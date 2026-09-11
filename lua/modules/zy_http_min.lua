--[[ zy_http_min — 无 curl/wget/python 设备的 HTTP 兜底（bash /dev/tcp 实现）
  适用：精简 rootless 设备（如 .61：无 curl/wget/python，只有 /var/jb/usr/bin/bash 与 coreutils）。
  约束：只处理 http:// 明文；HTTPS 请用引擎原生 httpGet 或 curl。
  API（全部返回 ok, 结果|错误）：
    M.get(url, timeout)              → ok, body
    M.post(url, body_string, timeout) → ok, body
    M.download(url, dest, timeout)   → ok, bytes
    M.available()                    → bool
]]
local M = { name = "zy_http_min", version = "1.0.0" }

local SH_PATH = "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH "

local function read_text(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function write_text(path, body)
  local ok = pcall(function()
    local f = io.open(path, "w")
    if not f then return end
    f:write(body); f:close()
  end)
  return ok
end

local function tmp_dir()
  for _, d in ipairs({ "/tmp", ".",
      (_G.ZIYAN_ZYCV and (_G.ZIYAN_ZYCV .. "/tmp")) or nil,
      (_G.ZIYAN_VAR and (_G.ZIYAN_VAR .. "/tmp")) or nil }) do
    if d then
      local probe = io.open(d .. "/.zy_http_probe", "w")
      if probe then
        probe:close(); os.remove(d .. "/.zy_http_probe"); return d
      end
    end
  end
  return "/tmp"
end

local function bash_exe()
  for _, p in ipairs({ "/var/jb/usr/bin/bash", "/var/jb/bin/bash", "/bin/bash", "/usr/bin/bash" }) do
    local f = io.open(p, "r")
    if f then f:close(); return p end
  end
  return nil
end

function M.available()
  return bash_exe() ~= nil
end

--- 运行时环境修复（.61 实测）：
--- ZiYan 运行时带 DYLD_LIBRARY_PATH=...:/var/jb/usr/lib/ziyan/lib，其中内置的旧
--- libreadline 缺少 _rl_set_timeout → bash 启动即 dyld 崩溃（dash 不需要 readline 所以正常）。
--- 所以调用 bash 前必须清空 DYLD_LIBRARY_PATH。
local function dyld_clean_prefix()
  if io.open("/var/jb/usr/bin/bash", "r") then
    return "DYLD_LIBRARY_PATH=/var/jb/usr/lib "
  end
  return "DYLD_LIBRARY_PATH= "
end

local SCRIPT = [[
#!/bin/bash
# zy_http_min 运行体：$1=mode(get|post|download) $2=url $3=bodyfile $4=outfile $5=statusfile $6=timeout
MODE="$1"; URL="$2"; BODY="$3"; OUT="$4"; STATUS="$5"; TMO="${6:-8}"
PROTO="${URL%%://*}"; REST="${URL#*://}"
HOSTPORT="${REST%%/*}"; URIPATH="/${REST#*/}"; URIPATH="${URIPATH%%//*}"
HOST="${HOSTPORT%%:*}"; PORT="${HOSTPORT##*:}"
[ "$PORT" = "$HOST" ] && PORT=80
: > "$STATUS"; : > "$OUT"
exec 3<>/dev/tcp/"$HOST"/"$PORT" || { echo "connect_failed" > "$STATUS"; exit 9; }
if [ "$MODE" = "post" ]; then
  LEN=$(wc -c < "$BODY" 2>/dev/null || echo 0)
  printf 'POST %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n' "$URIPATH" "$HOST" "$LEN" >&3
  cat "$BODY" >&3
else
  printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$URIPATH" "$HOST" >&3
fi
IFS= read -r STATUSLINE <&3 || true
printf '%s' "${STATUSLINE%$'\r'}" > "$STATUS"
while IFS= read -r hl <&3; do
  hl="${hl%$'\r'}"
  [ -z "$hl" ] && break
done
cat <&3 > "$OUT" &
CP=$!
( sleep "$TMO"; kill -9 "$CP" 2>/dev/null ) >/dev/null 2>&1 &
KP=$!
wait "$CP" 2>/dev/null
kill "$KP" 2>/dev/null
exec 3<&- 3>&-
exit 0
]]

local _script_path = nil

local function ensure_script()
  if _script_path then return _script_path end
  local p = tmp_dir() .. "/.zy_http_min.sh"
  if not write_text(p, SCRIPT) then return nil end
  _script_path = p
  return p
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run(mode, url, body_file, out_file, timeout)
  local bash = bash_exe()
  if not bash then return false, "no_bash" end
  local script = ensure_script()
  if not script then return false, "script_write_failed" end
  local status_file = out_file .. ".status"
  local cmd = dyld_clean_prefix() .. SH_PATH .. shell_quote(bash) .. " " .. shell_quote(script)
    .. " " .. mode
    .. " " .. shell_quote(url)
    .. " " .. shell_quote(body_file or "-")
    .. " " .. shell_quote(out_file)
    .. " " .. shell_quote(status_file)
    .. " " .. tostring(tonumber(timeout) or 8)
  -- rootless：io.popen 走 libc（/bin/sh 缺失）必死；os.execute 在 embed 被
  -- ziyan_ios_system 覆盖（/var/jb/bin/sh 优先）→ 用 os.execute，输出写文件
  pcall(function()
    os.execute(cmd .. " > /dev/null 2>&1")
  end)
  local status = read_text(status_file)
  local body = read_text(out_file)
  if status == "connect_failed" then return false, "connect_failed" end
  if not status or #status == 0 then return false, "no_response" end
  local code = tonumber(status:match("HTTP/%d%.%d (%d+)"))
  if not code then return false, "bad_status:" .. status:sub(1, 60) end
  if code < 200 or code >= 300 then return false, "http_" .. tostring(code) end
  return true, body or ""
end

function M.get(url, timeout)
  local out = tmp_dir() .. "/.zy_http_get_" .. tostring(os.time()) .. ".out"
  local ok, body = run("get", url, "-", out, timeout)
  os.remove(out); os.remove(out .. ".status")
  if not ok then return false, body end
  return true, body
end

function M.post(url, body_string, timeout)
  local stamp = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
  local bf = tmp_dir() .. "/.zy_http_body_" .. stamp .. ".txt"
  if not write_text(bf, tostring(body_string or "")) then return false, "body_write_failed" end
  local out = tmp_dir() .. "/.zy_http_post_" .. stamp .. ".out"
  local ok, resp = run("post", url, bf, out, timeout)
  os.remove(bf); os.remove(out); os.remove(out .. ".status")
  if not ok then return false, resp end
  return true, resp
end

function M.download(url, dest, timeout)
  local ok, body = run("down", url, "-", dest, timeout)
  if not ok then return false, body end
  local f = io.open(dest, "r")
  if not f then return false, "dest_missing" end
  local size = f:seek("end"); f:close()
  return true, size
end

return M
