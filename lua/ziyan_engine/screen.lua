--[[ 屏幕：keepScreen / snapshot / Screen 门面（阶段2）
  keepScreen 对齐触动习惯：true 先抓一帧并冻结找色缓冲，false 解冻并清缓存。
  screenSync / screenSize / screenKeep 为统一门面，供 Device→Screen→Coordinate 管线使用。
]]
local M = { module = "screen", version = "2.0.0" }

local function defined(n) return type(_G[n]) == "function" end

local function resolve_var()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function ipc_keep_screen(on)
  local var = resolve_var()
  local req = var .. "/.ziyan_color_req"
  local rep = var .. "/.ziyan_color_rep"
  local nonce = tostring(math.floor((os.clock() or 0) * 1000000) % 100000000)
  local tmp = req .. ".tmp." .. tostring(math.floor((os.clock() or 0) * 1e6) % 1e8)
  pcall(os.remove, rep)
  local f = io.open(tmp, "w")
  if not f then
    return false
  end
  f:write(string.format("keepScreen\n%d\n%s\n", on and 1 or 0, nonce))
  f:close()
  pcall(os.remove, req)
  local ok = os.rename(tmp, req)
  if not ok then
    f = io.open(req, "w")
    if not f then
      pcall(os.remove, tmp)
      return false
    end
    f:write(string.format("keepScreen\n%d\n%s\n", on and 1 or 0, nonce))
    f:close()
    pcall(os.remove, tmp)
  end
  local max_loops = 100
  for _ = 1, max_loops do
    local rf = io.open(rep, "r")
    if rf then
      local body = rf:read("*a") or ""
      rf:close()
      local lines = {}
      for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
        lines[#lines + 1] = line
      end
      if #lines >= 2 and lines[1] == nonce then
        pcall(os.remove, rep)
        return lines[2] == "ok"
      end
    end
    if type(mSleep) == "function" then
      mSleep(15)
    else
      os.execute("sleep 0.015")
    end
  end
  return false
end

function M.install()
  function keepScreen(on)
    local want = on and true or false
    local ok = ipc_keep_screen(want)
    if not ok then
      _G.__ZIYAN_KEEP_SCREEN = false
      return false
    end
    _G.__ZIYAN_KEEP_SCREEN = want
    return true
  end

  if not defined("isKeepScreen") then
    function isKeepScreen()
      return _G.__ZIYAN_KEEP_SCREEN and true or false
    end
  end

  if not defined("rotateScreen") then
    function rotateScreen(deg)
      _G.__ZIYAN_ROTATE = tonumber(deg) or 0
      return true
    end
  end
  if not defined("snapshot") then
    function snapshot(path, x1, y1, x2, y2)
      if type(dumpScreen) == "function" then
        return dumpScreen(path) ~= nil
      end
      if y2 ~= nil and defined("snapshotRegion") then
        return snapshotRegion(path, x1, y1, x2, y2)
      end
      if defined("snapshotScreen") then
        return snapshotScreen(path)
      end
      return false
    end
  end

  -- 阶段2：Screen 门面（包装已有 syncGameScreen / getScreenSize）
  function screenKeep(on)
    return keepScreen(on)
  end
  function screenSize()
    if defined("getScreenSize") then
      return getScreenSize()
    end
    return 1136, 640
  end
  function screenSync(orient, bid)
    orient = tonumber(orient) or tonumber(_G.__ZIYAN_ORIENT) or 1
    if defined("keepScreen") then pcall(keepScreen, false) end
    if defined("syncGameScreen") then
      return syncGameScreen(orient, bid)
    end
    if defined("softSync") then
      return softSync()
    end
    return false
  end
  function screenDump(path)
    if defined("dumpScreen") then
      return dumpScreen(path)
    end
    if defined("snapshot") then
      return snapshot(path)
    end
    return nil
  end
  _G.ZiYanScreen = M
  return M
end

return M
