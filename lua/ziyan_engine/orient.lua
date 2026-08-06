--[[
  坐标初始化 — 对齐触动精灵 init（.171/.149 实机 main.lua = init("0", 1)）
  文档：https://helpdoc.touchsprite.com/dev_docs/1.html
  维基：init(文本 bid, 整数 rotate)；bid="0" 跟当前前台。

  形态：
    init(rotate)        — 单参：0 竖屏 / 1 Home右 / 2 Home左
    init(bid, rotate)   — 双参：第一参 BundleID 或 "0"；第二参才是朝向

  注意（摘自触动手册）：
    · 可在运行中多次调用以改变方向
    · 未指定时默认为竖屏 / 初始方向
    · init 方向不受锁屏影响
    · 切前台 / 注销后应再 init 一次，防止方向错误（cv 找色前已接 sync）

  触摸精灵侧用 rotateScreen(90/-90/0) 对齐缓冲；失败则对竖屏缓冲做坐标换算。
]]

local M = { version = "2.0.3" }

local function defined(n) return type(_G[n]) == "function" end

local function orient_file()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR .. "/.ziyan_orient"
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var/.ziyan_orient"
  end
  return "/usr/lib/ziyan/var/.ziyan_orient"
end

local function read_orient_file()
  local path = orient_file()
  local f = io.open(path, "r")
  if not f then
    return nil, 0, 0
  end
  local o = tonumber((f:read("*l") or ""):match("-?%d+"))
  local lw = tonumber((f:read("*l") or ""):match("%d+")) or 0
  local lh = tonumber((f:read("*l") or ""):match("%d+")) or 0
  f:close()
  if o == nil or o < 0 or o > 2 then
    return nil, lw, lh
  end
  return o, lw, lh
end

-- R8.4.3：旁路 lua（SSH 一发 require/toast）禁止把主脚本横屏会话写成 init(0)
local function self_pid()
  for _, sh in ipairs({
    "/var/jb/bin/bash", "/var/jb/usr/bin/bash", "/bin/bash",
    "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/bin/sh",
  }) do
    local p = io.popen(string.format("'%s' -c 'echo $PPID' 2>/dev/null", sh))
    if p then
      local n = tonumber((p:read("*l") or ""):match("%d+"))
      p:close()
      if n and n > 1 then
        return n
      end
    end
  end
  return nil
end

local function foreign_land_session_blocks_portrait_write()
  if _G.__ZIYAN_INIT_CALLED then
    return false
  end
  local path = orient_file()
  local var = path:gsub("%.ziyan_orient$", "")
  local fo = select(1, read_orient_file())
  if not (fo == 1 or fo == 2) then
    return false
  end
  local has_session = io.open(var .. "/.ziyan_script_session", "r")
    or io.open(var .. "/.ziyan_project_active", "r")
  if has_session then
    has_session:close()
  else
    return false
  end
  local pf = io.open(var .. "/.ziyan_lua_run.pid", "r")
  local owner = nil
  if pf then
    owner = tonumber((pf:read("*l") or ""):match("%d+"))
    pf:close()
  end
  local me = self_pid()
  if owner and me and owner > 1 and owner ~= me then
    return true
  end
  -- pid 文件被旁路覆盖时：只要会话在且文件仍是横屏，未显式 init 也禁止降级
  return true
end

local function write_orient_file(orient, lw, lh)
  pcall(function()
    orient = tonumber(orient) or 0
    if orient == 0 and foreign_land_session_blocks_portrait_write() then
      local dbg = orient_file():gsub("%.ziyan_orient$", ".ziyan_orient_dbg")
      local d = io.open(dbg, "w")
      if d then
        d:write(string.format(
          "SKIP_WRITE_0 keep_land_session ts=%s\n",
          tostring(os.time())
        ))
        d:close()
      end
      return
    end
    local path = orient_file()
    local f = io.open(path, "w")
    local body = string.format("%s\n%s\n%s\n", tostring(orient), tostring(lw), tostring(lh))
    if f then
      f:write(body)
      f:close()
      pcall(os.execute, string.format("chmod 666 '%s' 2>/dev/null", path))
    else
      -- 8-136：root:644 锁死时写 req，由 framecap(root) 落盘
      local req = path:gsub("%.ziyan_orient$", ".ziyan_orient_req")
      local r = io.open(req, "w")
      if r then
        r:write(body)
        r:close()
      end
    end
    -- 双写 req：即使 open 成功也请求 root 放权/校正属主
    do
      local req = path:gsub("%.ziyan_orient$", ".ziyan_orient_req")
      local r = io.open(req, "w")
      if r then
        r:write(body)
        r:close()
      end
    end
    local dbg = path:gsub("%.ziyan_orient$", ".ziyan_orient_dbg")
    local d = io.open(dbg, "w")
    if d then
      local info = ""
      if type(M.debug_info) == "function" then
        local ok, s = pcall(M.debug_info)
        if ok then info = tostring(s) end
      end
      d:write(string.format(
        "orient=%s logic=%sx%s file=%s\n%s\n",
        tostring(orient), tostring(lw), tostring(lh), path, info
      ))
      d:close()
    end
  end)
end

local function state()
  local st = _G.__ZIYAN_ORIENT_STATE
  if type(st) ~= "table" then
    st = {
      orient = 0,
      pw = 640,
      ph = 1136,
      buf_land = false,
      te_rotated = false,
      raw_w = 640,
      raw_h = 1136,
    }
    _G.__ZIYAN_ORIENT_STATE = st
  end
  return st
end

--- 逻辑分辨率（init 后 getScreenSize 返回值）
function M.logical_size()
  local st = state()
  if st.orient == 0 then
    return st.pw, st.ph
  end
  -- init(1)/init(2)：横屏逻辑宽=长边，高=短边
  return st.ph, st.pw
end

--- 是否需要把「脚本逻辑坐标」换成引擎物理缓冲坐标
--- 只看真实缓冲横竖，不信任 te_rotated（TE rotateScreen 常“成功”但缓冲仍是竖屏）
local function need_rotate()
  local st = state()
  if st.orient == 0 then
    -- 竖屏逻辑：缓冲已是横屏时才需要换算
    return st.buf_land and true or false
  end
  if st.buf_land then
    -- 缓冲已横屏：init(1) 恒等；init(2) Home 左需再转
    return st.orient == 2
  end
  -- 竖屏缓冲 + init(1/2)：必须数学旋转
  return true
end

--[[
  触动：init(0) 竖屏 Home下；init(1) 横屏 Home右；init(2) 横屏 Home左
  竖屏物理缓冲 (pw×ph) ↔ 逻辑（与 ScreenBridge / OrientMap 一致）
  init(1)：logic(x,y) → phys(pw-y-1, x)   -- land=port(w-1-y,x)
  init(2)：logic(x,y) → phys(y, ph-x-1)   -- land=port(y,h-1-x)
]]
function M.to_phys(x, y)
  x, y = tonumber(x) or 0, tonumber(y) or 0
  local st = state()
  if not need_rotate() then
    return x, y
  end
  local pw, ph, o = st.pw, st.ph, st.orient
  if st.buf_land then
    if o == 0 then
      return ph - y - 1, x
    elseif o == 2 then
      return y, pw - x - 1
    end
    return x, y
  end
  if o == 1 then
    return pw - y - 1, x
  elseif o == 2 then
    return y, ph - x - 1
  end
  return x, y
end

function M.to_logic(px, py)
  px, py = tonumber(px) or 0, tonumber(py) or 0
  local st = state()
  if not need_rotate() then
    return px, py
  end
  local pw, ph, o = st.pw, st.ph, st.orient
  if st.buf_land then
    if o == 0 then
      return py, ph - px - 1
    elseif o == 2 then
      return pw - py - 1, px
    end
    return px, py
  end
  if o == 1 then
    -- phys(pw-y-1, x) 互逆：x = py, y = pw-1-px
    return py, pw - px - 1
  elseif o == 2 then
    -- phys(y, ph-x-1) 互逆：x = ph-1-py, y = px
    return ph - py - 1, px
  end
  return px, py
end

function M.offset_to_phys(dx, dy)
  dx, dy = tonumber(dx) or 0, tonumber(dy) or 0
  if not need_rotate() then
    return dx, dy
  end
  local st = state()
  local o = st.orient
  if st.buf_land then
    if o == 0 then
      return -dy, dx
    elseif o == 2 then
      return dy, -dx
    end
    return dx, dy
  end
  if o == 1 then
    -- d(phys) from d(logic) under (pw-y-1, x)
    return -dy, dx
  elseif o == 2 then
    return dy, -dx
  end
  return dx, dy
end

function M.rect_to_phys(x1, y1, x2, y2)
  x1, y1 = tonumber(x1) or 0, tonumber(y1) or 0
  x2, y2 = tonumber(x2) or 0, tonumber(y2) or 0
  if x2 < 0 and y2 < 0 then
    local lw, lh = M.logical_size()
    if need_rotate() then
      local st = state()
      if st.buf_land then
        return 0, 0, st.ph - 1, st.pw - 1
      end
      return 0, 0, st.pw - 1, st.ph - 1
    end
    return 0, 0, lw - 1, lh - 1
  end
  if not need_rotate() then
    return math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2)
  end
  local pts = {
    { M.to_phys(x1, y1) },
    { M.to_phys(x2, y1) },
    { M.to_phys(x1, y2) },
    { M.to_phys(x2, y2) },
  }
  local minx, maxx = pts[1][1], pts[1][1]
  local miny, maxy = pts[1][2], pts[1][2]
  for i = 2, 4 do
    local x, y = pts[i][1], pts[i][2]
    if x < minx then minx = x end
    if x > maxx then maxx = x end
    if y < miny then miny = y end
    if y > maxy then maxy = y end
  end
  return minx, miny, maxx, maxy
end

function M.colors_to_phys(colors)
  if type(colors) ~= "table" then
    return colors
  end
  if type(colors[1]) == "number" then
    local out = { colors[1] }
    local i = 2
    while i + 2 <= #colors do
      local dx, dy, col = colors[i], colors[i + 1], colors[i + 2]
      local pdx, pdy = M.offset_to_phys(dx, dy)
      out[#out + 1] = pdx
      out[#out + 1] = pdy
      out[#out + 1] = col
      i = i + 3
    end
    return out
  end
  local flat = {}
  for i, c in ipairs(colors) do
    if type(c) == "table" then
      local col = c[1] or c.color or 0
      local dx = c[2] or c.x or 0
      local dy = c[3] or c.y or 0
      if i == 1 then
        flat[1] = col
      else
        local pdx, pdy = M.offset_to_phys(dx, dy)
        flat[#flat + 1] = pdx
        flat[#flat + 1] = pdy
        flat[#flat + 1] = col
      end
    end
  end
  return flat
end

--- 触动 init(1) ≈ 安卓「向左旋转 90°」≈ TE rotateScreen(90)
function M.apply_te_rotate(orient)
  local rot = _G.__ZIYAN_NATIVE_ROTATE
  if type(rot) ~= "function" then
    return false
  end
  local deg = 0
  if orient == 1 then
    deg = 90
  elseif orient == 2 then
    deg = -90
  end
  local ok = pcall(rot, deg)
  if ok and type(mSleep) == "function" then
    pcall(mSleep, 80)
  end
  local st = state()
  M.refresh_buffer()
  -- 只有缓冲真的变成横屏，才算 TE 旋转生效
  if orient == 0 then
    st.te_rotated = ok and (not st.buf_land)
  else
    st.te_rotated = ok and st.buf_land or false
  end
  if ok and not st.te_rotated and deg ~= 0 then
    -- 旋转未改变缓冲尺寸：复位原生 rotate，改走数学换算
    pcall(rot, 0)
    if type(mSleep) == "function" then pcall(mSleep, 40) end
    M.refresh_buffer()
    st.te_rotated = false
    return false
  end
  return st.te_rotated
end

local function read_bridge_buf_wh()
  local candidates = {}
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    candidates[#candidates + 1] = _G.ZIYAN_VAR .. "/.ziyan_buf_wh"
  end
  candidates[#candidates + 1] = "/var/jb/usr/lib/ziyan/var/.ziyan_buf_wh"
  candidates[#candidates + 1] = "/usr/lib/ziyan/var/.ziyan_buf_wh"
  for _, p in ipairs(candidates) do
    local f = io.open(p, "r")
    if f then
      local w = tonumber((f:read("*l") or ""):match("%d+"))
      local h = tonumber((f:read("*l") or ""):match("%d+"))
      f:close()
      if w and h and w > 1 and h > 1 then
        return w, h
      end
    end
  end
  return nil, nil
end

function M.refresh_buffer()
  local st = state()
  -- 优先 ScreenBridge 实机缓冲（USB 高分 2208x1242），避免卡在 TE 640x1136
  local bw, bh = read_bridge_buf_wh()
  if bw and bh then
    st.raw_w, st.raw_h = bw, bh
    if bw > bh then
      st.buf_land = true
      st.pw, st.ph = bh, bw
    else
      st.buf_land = false
      st.pw, st.ph = bw, bh
      if st.orient == 1 or st.orient == 2 then
        st.te_rotated = false
      end
    end
    return st
  end

  local nativeRes = _G.__ZIYAN_NATIVE_GET_RES
  if type(nativeRes) ~= "function" then
    return st
  end
  local ok, a, b = pcall(nativeRes)
  if not (ok and tonumber(a) and tonumber(b)) then
    return st
  end
  local aw, ah = tonumber(a), tonumber(b)
  st.raw_w, st.raw_h = aw, ah
  if aw > ah then
    st.buf_land = true
    st.pw, st.ph = ah, aw
  else
    st.buf_land = false
    st.pw, st.ph = aw, ah
    -- 竖屏缓冲：禁止假装已横屏旋转
    if st.orient == 1 or st.orient == 2 then
      st.te_rotated = false
    end
  end
  return st
end

--- 业务脚本钉死的 init 方向（只读 init_args / __ZIYAN_ORIENT；禁止跟前台物理方向跑）
function M.pinned_orient()
  local o = tonumber(_G.__ZIYAN_ORIENT)
  if o ~= nil and o >= 0 and o <= 2 then
    return o
  end
  local fromArgs = nil
  do
    local path = orient_file():gsub("%.ziyan_orient$", ".ziyan_init_args")
    local f = io.open(path, "r")
    if f then
      f:read("*l") -- bid
      fromArgs = tonumber((f:read("*l") or ""):match("-?%d+"))
      f:close()
    end
  end
  if fromArgs ~= nil and fromArgs >= 0 and fromArgs <= 2 then
    _G.__ZIYAN_ORIENT = fromArgs
    return fromArgs
  end
  local fo = select(1, read_orient_file())
  if fo ~= nil then
    return fo
  end
  return 0
end

--- 循环内轻量同步：不改业务 rotate；只校正缓冲标志并重写 orient 文件（钉死方向）
function M.soft_sync()
  local pinned = M.pinned_orient()
  local st = state()
  st.orient = pinned
  _G.__ZIYAN_ORIENT = pinned
  _G.__ZIYAN_TE_ORIENT = pinned
  M.refresh_buffer()
  if (st.orient == 1 or st.orient == 2) and not st.buf_land then
    st.te_rotated = false
  end
  local lw, lh = M.logical_size()
  write_orient_file(st.orient, lw, lh)
  return st
end

--- 181：切前台只换像素；方向永远重申业务 init（禁止「跟前台一起变方向」）
function M.reassert_init_orient()
  local pinned = M.pinned_orient()
  local st = state()
  if st.orient ~= pinned then
    st.orient = pinned
    _G.__ZIYAN_ORIENT = pinned
    _G.__ZIYAN_TE_ORIENT = pinned
  end
  return M.soft_sync()
end

--[[
  ZiYan 自有：与游戏画面保持一致（学习 TS 习惯后的独立方案，不调用 TS 私有 API）

  观察习惯（.149）：
  · 脚本入口一次 init，死循环里靠固定延时等界面就绪
  · 开游/关游后用延时 + 状态判断，而不是每帧重算坐标
  · 找色前界面已稳定；切 App 后靠「再进入流程」恢复

  ZiYan 实现：
  1. 记录期望 orient + 目标 bundle
  2. 解除 keepScreen 冻帧（避免开游后仍用桌面缓存）
  3. 若逻辑缓冲方向与 init 不符 → 全量 set_orient；否则 soft_sync + 强制取色刷新
  4. 写入 .ziyan_game_sync 供三机对比
]]
local _last_sync_front = ""
local _last_sync_at = 0

function M.sync_game_screen(orient, expectBid)
  -- 181：传入 orient 仅作「与钉死方向一致性校验」；实际永远用 pinned，禁止跟前台改方向
  local pinned = M.pinned_orient()
  orient = tonumber(orient)
  if orient == nil or orient < 0 or orient > 2 then
    orient = pinned
  end
  -- 业务已 init 过则忽略外部想改成别的方向（防切 SB 被写成 0）
  if _G.__ZIYAN_INIT_CALLED and pinned ~= orient then
    orient = pinned
  end
  expectBid = tostring(expectBid or "")

  local front = ""
  if type(frontAppBid) == "function" then
    front = tostring(frontAppBid() or "")
  end
  local frontChanged = (front ~= _last_sync_front)
  if frontChanged then
    _last_sync_front = front
  end

  -- 切前台：不拆 keep、不改 rotate；只 soft_sync + 让调用方去 force_recap
  M.reassert_init_orient()
  if type(getColor) == "function" and frontChanged then
    pcall(getColor, 0, 0)
    M.reassert_init_orient()
  end
  _last_sync_at = os.clock()

  local st2 = state()
  local lw, lh = M.logical_size()
  -- matched=缓冲是否已横：仅诊断；竖屏缓冲 + init(1) 走数学换算仍算方向正确
  local matched = (st2.orient == orient)
  pcall(function()
    local path = orient_file():gsub("%.ziyan_orient$", ".ziyan_game_sync")
    local f = io.open(path, "w")
    if not f then return end
    f:write(string.format(
      "ts=%s orient=%d pinned=%d matched=%s front=%s expect=%s logic=%sx%s raw=%sx%s buf_land=%s\n",
      os.date("%H:%M:%S"), orient, pinned, tostring(matched), front, expectBid,
      tostring(lw), tostring(lh), tostring(st2.raw_w), tostring(st2.raw_h),
      tostring(st2.buf_land)))
    f:close()
  end)
  return matched
end

function M.set_orient(orient)
  orient = tonumber(orient) or 0
  if orient < 0 or orient > 2 then
    orient = 0
  end
  local st = state()
  st.orient = orient
  -- TE rotate 在 USB/iOS16 常无效；勿把 te_rot 标 true 造成与游戏画面假同步
  local teOk = M.apply_te_rotate(orient)
  if not teOk then
    st.te_rotated = false
  end
  _G.__ZIYAN_ORIENT = orient
  _G.__ZIYAN_TE_ORIENT = orient
  local lw, lh = M.logical_size()
  write_orient_file(orient, lw, lh)
  -- 多次触发截屏，直到 buf_wh 与 init 方向一致（横屏逻辑须 w>h）
  local matched = false
  for _ = 1, 5 do
    if type(getColor) == "function" then
      pcall(getColor, 0, 0)
    end
    if type(mSleep) == "function" then
      pcall(mSleep, 60)
    end
    M.refresh_buffer()
    lw, lh = M.logical_size()
    write_orient_file(orient, lw, lh)
    if orient == 0 then
      matched = (not st.buf_land) or (lw > 0 and lh > lw)
      if lw > 0 and lh > lw then
        -- 缓冲仍是横的但 init(0)：接受物理横缓冲
        matched = true
      end
      if not st.buf_land then matched = true end
    else
      matched = st.buf_land == true and lw >= lh
    end
    if matched then break end
  end
  lw, lh = M.logical_size()
  write_orient_file(orient, lw, lh)
  pcall(function()
    local path = orient_file():gsub("%.ziyan_orient$", ".ziyan_init_sync")
    local f = io.open(path, "w")
    if not f then return end
    f:write(string.format(
      "orient=%d matched=%s te_rot=%s buf_land=%s logic=%sx%s raw=%sx%s\n",
      orient, tostring(matched), tostring(st.te_rotated), tostring(st.buf_land),
      tostring(lw), tostring(lh), tostring(st.raw_w), tostring(st.raw_h)))
    f:close()
  end)
  return orient
end

function M.get_orient()
  return state().orient
end

function M.debug_info()
  local st = state()
  local lw, lh = M.logical_size()
  return string.format(
    "init=%s te_rot=%s buf_land=%s raw=%sx%s logic=%sx%s need_rot=%s",
    tostring(st.orient),
    tostring(st.te_rotated),
    tostring(st.buf_land),
    tostring(st.raw_w or "?"),
    tostring(st.raw_h or "?"),
    tostring(lw),
    tostring(lh),
    tostring(need_rotate())
  )
end

function M.install()
  if not _G.__ZIYAN_NATIVE_GET_RES and defined("getScreenResolution") then
    _G.__ZIYAN_NATIVE_GET_RES = getScreenResolution
  end
  if not _G.__ZIYAN_NATIVE_ROTATE and defined("rotateScreen") then
    _G.__ZIYAN_NATIVE_ROTATE = rotateScreen
  end
  if not _G.__ZIYAN_NATIVE_getColor and defined("getColor") then
    _G.__ZIYAN_NATIVE_getColor = getColor
  end

  --- 触动 init（对齐 .171/.149 手册 / 维基）
  ---   init(rotate)           — 单参：0 竖屏 / 1 Home右 / 2 Home左
  ---   init(bid, rotate)      — 双参：bid="0" 跟当前前台；第二参才是朝向
  --- 铁律：切前台后应再 init（手册）；见 sync_game_screen / find 前 front 变化重同步
  --- 旧误实现：init("0",1) 把 tonumber("0")==0 当成竖屏 → 切 App 找色/点击全乱
  function init(a, b)
    local bid, orient
    if b ~= nil then
      -- 双参：init(bid, rotate) — 与触动 init("0", 1) 一致
      bid = tostring(a ~= nil and a or "0")
      orient = tonumber(b)
      if orient == nil then
        orient = 0
      end
    else
      -- 单参：init(1) / init("1")
      bid = "0"
      orient = tonumber(a)
      if orient == nil then
        -- 仅字符串 bid 无朝向：跟当前横屏会话或默认 0
        if type(a) == "string" and not tostring(a):match("^%s*-?%d+%s*$") then
          bid = a
          orient = tonumber(_G.__ZIYAN_ORIENT) or 0
        else
          orient = 0
        end
      end
    end
    if orient < 0 or orient > 2 then
      orient = 0
    end
    _G.__ZIYAN_INIT_CALLED = true
    _G.__ZIYAN_INIT_BID = bid
    _G.__ZIYAN_ORIENT = orient
    -- 记录供切前台后重 init（对标触动手册）
    pcall(function()
      local path = orient_file():gsub("%.ziyan_orient$", ".ziyan_init_args")
      local f = io.open(path, "w")
      if f then
        f:write(string.format("%s\n%d\n", tostring(bid), orient))
        f:close()
      end
    end)
    return M.set_orient(orient)
  end

  --- 轻量同步 / 与游戏画面对齐（全局）
  function softSync()
    return M.soft_sync()
  end
  function syncGameScreen(orient, expectBid)
    return M.sync_game_screen(orient, expectBid)
  end

  --- 返回 init 后的逻辑分辨率
  function getScreenSize()
    return M.logical_size()
  end
  function getScreenResolution()
    return M.logical_size()
  end

  if type(_G.__ZIYAN_NATIVE_ROTATE) == "function" then
    function rotateScreen(deg)
      deg = tonumber(deg) or 0
      local ok = pcall(_G.__ZIYAN_NATIVE_ROTATE, deg)
      local st = state()
      if deg == 0 then
        st.orient = 0
      elseif deg == 90 or deg == -270 then
        st.orient = 1
      elseif deg == -90 or deg == 270 then
        st.orient = 2
      end
      _G.__ZIYAN_ORIENT = st.orient
      M.refresh_buffer()
      -- 竖屏缓冲时不算旋转成功
      if deg == 0 then
        st.te_rotated = ok and (not st.buf_land)
      else
        st.te_rotated = ok and st.buf_land or false
        if ok and not st.te_rotated then
          pcall(_G.__ZIYAN_NATIVE_ROTATE, 0)
          M.refresh_buffer()
          st.te_rotated = false
        end
      end
      local lw, lh = M.logical_size()
      write_orient_file(st.orient, lw, lh)
      return st.te_rotated
    end
  end

  _G.ZiYanOrient = M
  if _G.__ZIYAN_ORIENT == nil then
    -- R8.4.3：require 默认勿覆盖已有横屏会话（.166 旁路 toast 曾写成 init=0 → Toast followScreen 错边）
    local fo, flw, flh = read_orient_file()
    if fo == 1 or fo == 2 then
      local st = state()
      st.orient = fo
      _G.__ZIYAN_ORIENT = fo
      _G.__ZIYAN_TE_ORIENT = fo
      if flw > 0 and flh > 0 then
        if fo == 0 then
          st.pw, st.ph = flw, flh
        else
          -- 文件存的是逻辑横屏宽高 → 还原竖屏物理边
          st.pw, st.ph = math.min(flw, flh), math.max(flw, flh)
        end
      end
      M.refresh_buffer()
    else
      M.set_orient(0)
    end
  else
    M.set_orient(_G.__ZIYAN_ORIENT)
  end
  return M
end

return M
