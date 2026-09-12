-- Run with the installed device engine; host tests only validate this fixture.
local config = _G.API_FUNCTIONAL_CONFIG or {}
local root = assert(config.root or os.getenv("API_ROOT"))
local out = assert(config.out or os.getenv("API_OUT"))
local family = assert(config.family or os.getenv("API_FAMILY"))
local run_id = assert(config.run_id or os.getenv("API_RUN_ID"))
_G.ZIYAN_ROOT = root
_G.ZIYAN_VAR = root .. "/var"
_G.ZIYAN_LUA = root .. "/lib/lua"
package.path = _G.ZIYAN_LUA .. "/?.lua;" .. _G.ZIYAN_LUA .. "/?/init.lua;" .. package.path
require("ziyan_engine")
local json = require("json")
local stream = assert(io.open(out .. "/results.jsonl", "w"))
local function emit(row)
  row.run_id = run_id
  stream:write(json.encode(row), "\n")
  stream:flush()
end
local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end
local function write(path, body)
  local f = assert(io.open(path, "wb"))
  f:write(body)
  f:close()
end
local spec = json.decode(assert(read(out .. "/cases.json")))
emit({event = "host", embedded = type(_G.ziyan_embed_msleep) == "function"})
for _, item in ipairs(spec.cases) do
  local value = _G
  for part in item["function"]:gmatch("[^.]+") do
    value = type(value) == "table" and value[part] or nil
  end
  emit({event = "binding", case_id = item.case_id,
    status = type(value) == "function" and "RUNTIME_PRESENT" or "MISSING_RUNTIME"})
end
local checks = {}
local function case(name, dimension, fn)
  checks[#checks + 1] = {id = name, dimension = dimension, fn = fn}
end
local a, b, c = out .. "/a.txt", out .. "/b.txt", out .. "/c.txt"
local payload = "api-functional:" .. run_id .. "\nline2"
if family == "file" then
  case("FileExists", "normal", function()
    write(a, payload)
    assert(FileExists(a) == true and FileExists(out .. "/missing") == false)
  end)
  case("FileExists", "error", function() assert(FileExists("") == false) end)
  case("FileCreate", "normal", function()
    assert(FileCreate(a, payload) == true and read(a) == payload)
  end)
  case("FileCreate", "error", function() assert(FileCreate("", "x") == false) end)
  case("FileCopy", "normal", function()
    write(a, payload)
    assert(FileCopy(a, b) == true and read(b) == payload and read(a) == payload)
  end)
  case("FileCopy", "error", function()
    assert(FileCopy(out .. "/missing", c) == false and read(c) == nil)
  end)
  case("FileMove", "normal", function()
    write(a, payload)
    assert(FileMove(a, c) == true and read(a) == nil and read(c) == payload)
    os.remove(c)
  end)
  case("FileMove", "error", function()
    assert(FileMove(out .. "/missing", c) == false and read(c) == nil)
  end)
  case("FileDelete", "normal", function()
    write(a, payload)
    assert(FileDelete(a) == true and read(a) == nil)
  end)
  case("FileDelete", "error", function() assert(FileDelete("") == false) end)
  case("FileList", "normal", function()
    write(a, payload)
    local items = FileList(out, false)
    assert(type(items) == "table")
    local found = false
    for _, item in ipairs(items) do if item == "a.txt" then found = true end end
    assert(found, "a.txt absent from listing")
  end)
  case("FileList", "error", function()
    local items = FileList(out .. "/missing", false)
    assert(type(items) == "table" and #items == 0)
  end)
  case("readFileString", "normal", function()
    write(a, payload)
    assert(readFileString(a) == payload)
  end)
  case("writeFileString", "normal", function()
    assert(writeFileString(a, payload) == true and read(a) == payload)
  end)
  case("PlistRead", "normal", function()
    write(out .. "/input.plist", '<?xml version="1.0"?><plist version="1.0"><dict>'
      .. '<key>marker</key><string>' .. run_id .. '</string>'
      .. '<key>count</key><integer>7</integer></dict></plist>')
    local value = PlistRead(out .. "/input.plist")
    assert(type(value) == "table" and value.marker == run_id and value.count == 7,
      "known plist content not returned")
  end)
  case("PlistRead", "error", function()
    assert(PlistRead(out .. "/missing.plist") == nil, "missing plist returned stale data")
  end)
  case("PlistRead", "error", function()
    write(out .. "/corrupt.plist", "not a plist")
    assert(PlistRead(out .. "/corrupt.plist") == nil, "corrupt plist returned stale data")
  end)
  case("PlistWrite", "normal", function()
    local path = out .. "/written.plist"
    assert(PlistWrite(path, {marker = run_id, count = 7, empty = jsonDecode("{}")}) == true,
      "PlistWrite returned false")
    assert(read(path) and #read(path) > 0, "plist not written")
    -- The host independently parses this artifact before crediting this check.
  end)
  case("PlistWrite", "error", function() assert(PlistWrite("", {}) == false) end)
  case("PlistWrite", "error", function()
    assert(PlistWrite(out, {marker = run_id}) == false, "directory accepted as plist file")
  end)
elseif family == "codec" then
  case("jsonEncode", "normal", function()
    assert(jsonEncode({marker = run_id}) == '{"marker":"' .. run_id .. '"}')
    assert(jsonEncode(jsonDecode("{}")) == "{}", "decoded empty object changed into array")
    assert(jsonEncode(jsonDecode("[]")) == "[]", "empty array changed into object")
  end)
  case("jsonDecode", "normal", function()
    local value = jsonDecode('{"marker":"' .. run_id .. '","n":7,"ok":true}')
    assert(value.marker == run_id and value.n == 7 and value.ok == true)
  end)
  case("jsonDecode", "error", function()
    assert(jsonDecode("") == nil and jsonDecode("{bad") == nil)
  end)
elseif family == "memory" then
  local bid = "com.ziyan.api-functional." .. run_id
  case("MemoryWrite", "normal", function()
    assert(MemoryWrite(bid, "marker", run_id) == true)
    local value = json.decode(assert(read(root .. "/var/memory/" .. bid .. ".json")))
    assert(value.marker == run_id, "cache not persisted")
  end)
  case("MemoryWrite", "error", function()
    assert(MemoryWrite("", "x", "y") == false and MemoryWrite(bid, "", "y") == false)
  end)
  case("MemoryAccess", "normal", function()
    write(root .. "/var/memory/" .. bid .. ".json", '{"marker":"' .. run_id .. '"}')
    assert(MemoryAccess(bid, "marker") == run_id)
  end)
  case("MemoryKeys", "normal", function()
    write(root .. "/var/memory/" .. bid .. ".json", '{"marker":"' .. run_id .. '"}')
    local value = MemoryKeys(bid)
    assert(value.ok == true and #value.keys == 1 and value.keys[1] == "marker")
  end)
  case("MemoryDump", "normal", function()
    write(root .. "/var/memory/" .. bid .. ".json", '{"marker":"' .. run_id .. '"}')
    local value = MemoryDump(bid, 10)
    assert(type(value) == "table" and value.ok == true and value.count == 1
      and #value.items == 1 and value.items[1].key == "marker"
      and value.items[1].value == run_id, "MemoryDump content mismatch")
    write(out .. "/memory_dump.json", json.encode(value))
  end)
elseif family == "orient" then
  -- 幂等策略：init 一律以「当前朝向」重入（不改设备朝向状态）；只验证语义与返回。
  local Ori = _G.ZiYanOrient
  local function current_orient()
    if type(Ori) == "table" and type(Ori.get_orient) == "function" then
      local ok, value = pcall(Ori.get_orient)
      if ok and type(value) == "number" then return value end
    end
    return tonumber(_G.__ZIYAN_ORIENT) or 0
  end
  -- 停止态判定（与引擎 control.lua/shm.lua 同源）：文件标志 或 shm flags STOP 位
  local function device_stopped()
    local var = root .. "/var"
    local f = io.open(var .. "/.ziyan_stop", "r")
    if f then f:close(); return true end
    local sf = io.open(var .. "/.ziyan_control_shm", "rb")
    if sf then
      sf:seek("set", 16)
      local b = sf:read(4)
      sf:close()
      if type(b) == "string" and #b == 4 then
        local v = b:byte(1) + b:byte(2) * 256 + b:byte(3) * 65536 + b:byte(4) * 16777216
        return (math.floor(v / 2) % 2) == 1
      end
    end
    return false
  end
  case("ZiYanOrient.logical_size", "normal", function()
    assert(type(Ori) == "table" and type(Ori.logical_size) == "function", "ZiYanOrient missing")
    local w, h = Ori.logical_size()
    assert(type(w) == "number" and type(h) == "number" and w > 0 and h > 0,
      "logical_size invalid: " .. tostring(w) .. "x" .. tostring(h))
    write(out .. "/orient_size.txt", tostring(w) .. "x" .. tostring(h) .. " orient=" .. tostring(current_orient()) .. "\n")
  end)
  case("ZiYanOrient.logical_size", "error", function()
    local w, h = Ori.logical_size()
    local w2, h2 = Ori.logical_size("junk", {})  -- 多余参数必须被忽略（不抛错、不改变结果）
    assert(w == w2 and h == h2, "logical_size changed with extra args")
  end)
  case("ZiYanOrient.to_phys", "normal", function()
    local lw, lh = Ori.logical_size()
    local x, y = math.floor(lw / 3), math.floor(lh / 2)
    local px, py = Ori.to_phys(x, y)
    assert(type(px) == "number" and type(py) == "number", "to_phys non-number")
    local bx, by = Ori.to_logic(px, py)
    assert(bx == x and by == y,
      ("to_phys round-trip %d,%d -> %s,%s -> %s,%s"):format(x, y, px, py, bx, by))
  end)
  case("ZiYanOrient.to_phys", "error", function()
    local ax, ay = Ori.to_phys("bad", nil)   -- 非数字 → 按 0 处理（不得抛错）
    local zx, zy = Ori.to_phys(0, 0)
    assert(ax == zx and ay == zy, "to_phys invalid input should coerce to 0")
  end)
  case("ZiYanOrient.to_logic", "normal", function()
    local lw, lh = Ori.logical_size()
    local px, py = math.floor(lw / 4), math.floor(lh / 5)
    local x, y = Ori.to_logic(px, py)
    assert(type(x) == "number" and type(y) == "number", "to_logic non-number")
    local bx, by = Ori.to_phys(x, y)
    assert(bx == px and by == py,
      ("to_logic round-trip %d,%d -> %s,%s -> %s,%s"):format(px, py, x, y, bx, by))
  end)
  case("ZiYanOrient.to_logic", "error", function()
    local ax, ay = Ori.to_logic({}, "bad")
    local zx, zy = Ori.to_logic(0, 0)
    assert(ax == zx and ay == zy, "to_logic invalid input should coerce to 0")
  end)
  case("init", "normal", function()
    -- 停止态下 init 会命中产品的「停止→干净退出」路径（会终止本进程）：
    -- 不加戏、不改设备状态，如实标记为未测（runner 侧 SKIPPED ≠ PASS）。
    if device_stopped() then return "SKIPPED:device_stopped" end
    local cur = current_orient()
    local r = init(cur)                      -- 幂等：与当前朝向一致
    assert(r == cur, ("init(%d) returned %s"):format(cur, tostring(r)))
    assert(tonumber(_G.__ZIYAN_ORIENT) == cur, "global orient changed")
    local w, h = Ori.logical_size()
    assert(type(w) == "number" and type(h) == "number" and w > 0 and h > 0, "size after init invalid")
    if type(getScreenSize) == "function" then
      local gw, gh = getScreenSize()
      assert(gw == w and gh == h, "getScreenSize != logical_size after init")
    end
    write(out .. "/orient_init.txt", ("init(%d) ok size=%dx%d\n"):format(cur, w, h))
  end)
  case("init", "error", function()
    if device_stopped() then return "SKIPPED:device_stopped" end
    local cur = current_orient()
    local r = init("junk")                   -- 非数字单参：回落当前朝向（不抛错、不改变状态）
    assert(r == cur, ("init(junk) returned %s, expected %d"):format(tostring(r), cur))
    assert(tonumber(_G.__ZIYAN_ORIENT) == cur, "global orient changed by invalid init")
  end)
end
for _, check in ipairs(checks) do
  for attempt = 1, (check.dimension == "normal" and 3 or 1) do
    emit({event = "start", case_id = family .. "." .. check.id,
      dimension = check.dimension, attempt = attempt})
    local ok, err = pcall(check.fn)
    local status, detail = "SCENARIO_PASS", ""
    if not ok then
      status, detail = "SCENARIO_FAIL", tostring(err)
    elseif type(err) == "string" and err:match("^SKIPPED:") then
      status, detail = "SCENARIO_SKIPPED", err
    end
    emit({event = "result", case_id = family .. "." .. check.id,
      dimension = check.dimension, attempt = attempt,
      status = status, detail = detail})
  end
end
emit({event = "final", family = family, terminal = true})
stream:close()
