--[[ Lua → Python：pyCall("demo_add","add",{2,3}) ]]
local OUT = "/usr/lib/ziyan/var/.ziyan_res_interop_test.txt"

local function write_out(s)
  local f = io.open(OUT, "w")
  if f then
    f:write(s)
    f:close()
  end
end

function main()
  if type(pyCall) ~= "function" then
    -- 引擎未装时手动加载
    pcall(dofile, "/usr/lib/ziyan/lib/lua/ziyan_engine/init.lua")
  end
  if type(pyCall) ~= "function" then
    write_out("FAIL pyCall missing\n")
    return
  end
  local ok, r = pyCall("demo_add", "add", { 2, 3 })
  if ok and r == 5 then
    write_out("PASS lua->py add=5\n")
    if type(toast) == "function" then
      toast("res interop PASS", 1500)
    end
  else
    write_out(string.format("FAIL lua->py ok=%s r=%s\n", tostring(ok), tostring(r)))
  end
end
