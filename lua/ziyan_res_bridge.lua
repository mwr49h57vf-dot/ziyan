--[[
  Python → Lua 互通桥（由 ziyan_res.lua_call 调用）
  用法: lua5.3 ziyan_res_bridge.lua --req <req.json> --rep <rep.json>
]]
local RES_DIR = "/private/var/mobile/Media/ZiYan/ZYCV/res"
local LUA_LIB = "/usr/lib/ziyan/lib/lua"
local ENGINE = LUA_LIB .. "/ziyan_engine"

package.path = table.concat({
  RES_DIR .. "/?.lua",
  RES_DIR .. "/?/init.lua",
  LUA_LIB .. "/?.lua",
  LUA_LIB .. "/?/init.lua",
  ENGINE .. "/?.lua",
  package.path or "",
}, ";")

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
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

local function load_json()
  local ok, json = pcall(require, "json")
  if ok and json then
    return json
  end
  return nil
end

local function fail(rep, err)
  local json = load_json()
  local body = json and json.encode({ ok = false, error = tostring(err) })
    or ('{"ok":false,"error":"' .. tostring(err):gsub('"', '\\"') .. '"}')
  write_file(rep, body)
  os.exit(1)
end

local function ok_rep(rep, result)
  local json = load_json()
  if not json then
    fail(rep, "json module missing")
  end
  write_file(rep, json.encode({ ok = true, result = result }))
  os.exit(0)
end

local function parse_argv(argv)
  local req, rep
  local i = 1
  while i <= #argv do
    if argv[i] == "--req" and argv[i + 1] then
      req = argv[i + 1]
      i = i + 2
    elseif argv[i] == "--rep" and argv[i + 1] then
      rep = argv[i + 1]
      i = i + 2
    else
      i = i + 1
    end
  end
  return req, rep
end

local function resolve_lua_module(mod)
  mod = tostring(mod or "")
  if mod == "" then
    return nil, "empty module"
  end
  if mod:sub(1, 1) == "/" or mod:find("%.lua$") then
    local p = mod
    if not p:find("%.lua$") then
      p = p .. ".lua"
    end
    if p:sub(1, 1) ~= "/" then
      p = RES_DIR .. "/" .. p
    end
    return p
  end
  local p = RES_DIR .. "/" .. mod .. ".lua"
  return p
end

local function load_and_call(mod, func, args)
  local path, err = resolve_lua_module(mod)
  if not path then
    return nil, err
  end
  local chunk, lerr = loadfile(path)
  if not chunk then
    return nil, "loadfile: " .. tostring(lerr)
  end
  local ok, ret = pcall(chunk)
  if not ok then
    return nil, "exec: " .. tostring(ret)
  end
  local fn = _G[func]
  if type(fn) ~= "function" and type(ret) == "table" and type(ret[func]) == "function" then
    fn = ret[func]
  end
  if type(fn) ~= "function" then
    return nil, "function not found: " .. tostring(func)
  end
  args = type(args) == "table" and args or {}
  local packed = { pcall(fn, table.unpack(args)) }
  if not packed[1] then
    return nil, "call: " .. tostring(packed[2])
  end
  if #packed == 2 then
    return packed[2]
  end
  local out = {}
  for i = 2, #packed do
    out[#out + 1] = packed[i]
  end
  return out
end

local req, rep = parse_argv(arg or {})
if not req or not rep then
  io.stderr:write("usage: ziyan_res_bridge.lua --req <f> --rep <f>\n")
  os.exit(2)
end

local json = load_json()
if not json then
  fail(rep, "json module missing")
end

local raw = read_file(req)
if not raw then
  fail(rep, "cannot read req")
end
local okj, payload = pcall(json.decode, raw)
if not okj or type(payload) ~= "table" then
  fail(rep, "bad req json")
end

local op = payload.op or "call_lua"
if op == "call_lua" then
  local result, err = load_and_call(payload.module, payload.func, payload.args)
  if err then
    fail(rep, err)
  end
  ok_rep(rep, result)
elseif op == "eval_lua" then
  local path = tostring(payload.path or "")
  if path:sub(1, 1) ~= "/" then
    path = RES_DIR .. "/" .. path
  end
  local chunk, lerr = loadfile(path)
  if not chunk then
    fail(rep, "loadfile: " .. tostring(lerr))
  end
  local ok, ret = pcall(chunk)
  if not ok then
    fail(rep, "exec: " .. tostring(ret))
  end
  if type(_G.main) == "function" then
    local ok2, ret2 = pcall(_G.main)
    if not ok2 then
      fail(rep, "main: " .. tostring(ret2))
    end
    ok_rep(rep, ret2)
  else
    ok_rep(rep, ret)
  end
else
  fail(rep, "unknown op: " .. tostring(op))
end
