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
end
for _, check in ipairs(checks) do
  for attempt = 1, (check.dimension == "normal" and 3 or 1) do
    emit({event = "start", case_id = family .. "." .. check.id,
      dimension = check.dimension, attempt = attempt})
    local ok, err = pcall(check.fn)
    emit({event = "result", case_id = family .. "." .. check.id,
      dimension = check.dimension, attempt = attempt,
      status = ok and "SCENARIO_PASS" or "SCENARIO_FAIL", detail = ok and "" or tostring(err)})
  end
end
emit({event = "final", family = family, terminal = true})
stream:close()
