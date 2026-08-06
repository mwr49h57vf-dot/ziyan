--[[ res/ Lua↔Python 互通：子进程 + JSON IPC ]]
local M = {}

local ZIYAN_VAR = _G.ZIYAN_VAR
if type(ZIYAN_VAR) ~= "string" or ZIYAN_VAR == "" then
  ZIYAN_VAR = (io.open("/var/jb/usr/lib/ziyan/var", "r") and "/var/jb/usr/lib/ziyan/var")
    or "/usr/lib/ziyan/var"
end
local RES_DIR = "/private/var/mobile/Media/ZiYan/ZYCV/res"
local ZIYAN_ROOT = _G.ZIYAN_ROOT
if type(ZIYAN_ROOT) ~= "string" or ZIYAN_ROOT == "" then
  ZIYAN_ROOT = ZIYAN_VAR:gsub("/var$", "")
end
local PY = ZIYAN_ROOT .. "/bin/python3"
local PY_BRIDGE = ZIYAN_ROOT .. "/bin/ziyan_cv/ziyan_res.py"
local REQ = ZIYAN_VAR .. "/.ziyan_res_req.json"
local REP = ZIYAN_VAR .. "/.ziyan_res_rep.json"
local STOP = ZIYAN_VAR .. "/.ziyan_stop"

local function checkpoint()
  if type(_G.__ZIYAN_wait_while_paused) == "function" then
    _G.__ZIYAN_wait_while_paused()
  end
  local f = io.open(STOP, "r")
  if f then
    f:close()
    error("ziyan_stop", 0)
  end
end

local function write_file(path, body)
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(body or "")
  f:close()
  return true
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function encode(t)
  if type(jsonEncode) == "function" then
    return jsonEncode(t)
  end
  local ok, json = pcall(require, "json")
  if ok and json and json.encode then
    return json.encode(t)
  end
  return nil
end

local function decode(s)
  if not s or s == "" then
    return nil
  end
  if type(jsonDecode) == "function" then
    return jsonDecode(s)
  end
  local ok, json = pcall(require, "json")
  if ok and json and json.decode then
    local ok2, t = pcall(json.decode, s)
    if ok2 then
      return t
    end
  end
  return nil
end

local function run_py_bridge(payload, timeout_s)
  timeout_s = tonumber(timeout_s) or 30
  pcall(os.remove, REP)
  local body = encode(payload)
  if not body then
    return false, "jsonEncode unavailable"
  end
  if not write_file(REQ, body) then
    return false, "cannot write " .. REQ
  end
  local py_path = table.concat({
    ZIYAN_ROOT .. "/bin/ziyan_cv",
    ZIYAN_ROOT .. "/bin",
    RES_DIR,
  }, ":")
  local env = string.format(
    'PYTHONPATH="%s:$PYTHONPATH" PYTHONDONTWRITEBYTECODE=1',
    py_path
  )
  local errlog = ZIYAN_VAR .. "/.ziyan_res_py_err"
  local cmd = string.format(
    '%s timeout %d %s %s --req "%s" --rep "%s" 2>%s',
    env,
    math.max(1, math.floor(timeout_s)),
    PY,
    PY_BRIDGE,
    REQ,
    REP,
    errlog
  )
  -- timeout 可能不存在：无 timeout 回退
  local st = os.execute(cmd)
  if st ~= true and st ~= 0 then
    local cmd2 = string.format(
      '%s %s %s --req "%s" --rep "%s" 2>%s',
      env,
      PY,
      PY_BRIDGE,
      REQ,
      REP,
      errlog
    )
    os.execute(cmd2)
  end
  local raw = read_file(REP)
  if not raw then
    local err = read_file(ZIYAN_VAR .. "/.ziyan_res_py_err") or ""
    return false, "no reply from python: " .. err
  end
  local t = decode(raw)
  if type(t) ~= "table" then
    return false, "bad json reply"
  end
  if t.ok then
    return true, t.result
  end
  return false, t.error or "python call failed"
end

function M.install()
  --- pyCall(moduleOrPath, func, argsTable?, opts?) -> ok, result|error
  --- moduleOrPath: "demo_add" 或 "/path/to/x.py" 或 "demo_add.py"
  function pyCall(moduleOrPath, func, args, opts)
    checkpoint()
    opts = type(opts) == "table" and opts or {}
    local ok, res = run_py_bridge({
      op = "call_py",
      module = tostring(moduleOrPath or ""),
      func = tostring(func or ""),
      args = type(args) == "table" and args or {},
    }, opts.timeout)
    return ok, res
  end

  --- pyEval(path, opts?) -> ok, result|error
  --- 运行整个 py；若脚本打印 ZIYAN_JSON:{...} 或写 result 字段则解析
  function pyEval(path, opts)
    checkpoint()
    opts = type(opts) == "table" and opts or {}
    local ok, res = run_py_bridge({
      op = "eval_py",
      path = tostring(path or ""),
    }, opts.timeout)
    return ok, res
  end

  _G.pyCall = pyCall
  _G.pyEval = pyEval
  return M
end

return M
