--[[
  原生找色桥：embed 热路径优先；冷路径才 .ziyan_color_req/rep
  ------------------------------------------------------------
  与子砚抓色器生成代码同架构（勿改参序/返回值）：
    x, y = findMultiColorInRegionFuzzy(0x主色, "dx|dy|0x..,...", degree, x1,y1,x2,y2)
  别名 findMultiColor 同参；走内存截屏扫描；逻辑坐标与 init(0/1/2) 对齐，偏移不 phys 旋转。
  8-161-81：窄 ROI / 紧邻偏点 → Oc ColorMatch ts_strict 首命中（无 pad/邻域）。
  193 / E1：ZIYAN_EMBED 时 find/getColor/keep 禁写 color_req；统计 .ziyan_path_stats
  回退旧择优：touch VAR/.ziyan_find_legacy
]]

local M = {}

local function resolve_var()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local VAR = resolve_var()
local COLOR_REQ = VAR .. "/.ziyan_color_req"
local COLOR_REP = VAR .. "/.ziyan_color_rep"
local SB_ALIVE = VAR .. "/.ziyan_sb_alive"
local PATH_STATS = VAR .. "/.ziyan_path_stats"

-- 193 E1：热路径 via 计数（flush → .ziyan_path_stats）
local _ps_embed_find, _ps_color_req_find = 0, 0
local _ps_embed_get, _ps_color_req_get = 0, 0
local _ps_embed_keep, _ps_color_req_keep = 0, 0
local _ps_last_flush = 0

local function refresh_paths()
  VAR = resolve_var()
  COLOR_REQ = VAR .. "/.ziyan_color_req"
  COLOR_REP = VAR .. "/.ziyan_color_rep"
  SB_ALIVE = VAR .. "/.ziyan_sb_alive"
  PATH_STATS = VAR .. "/.ziyan_path_stats"
end

local function flush_path_stats(force)
  local now = os.time() or 0
  if not force and (now - (_ps_last_flush or 0)) < 2 then
    return
  end
  _ps_last_flush = now
  pcall(function()
    refresh_paths()
    local f = io.open(PATH_STATS, "w")
    if not f then return end
    f:write(string.format(
      "ts=%d via_embed_find=%d via_color_req_find=%d via_embed_get=%d via_color_req_get=%d via_embed_keep=%d via_color_req_keep=%d embed=%s\n",
      now, _ps_embed_find, _ps_color_req_find, _ps_embed_get, _ps_color_req_get,
      _ps_embed_keep, _ps_color_req_keep, tostring(_G.ZIYAN_EMBED and true or false)))
    f:close()
  end)
end

--- embed 热路径禁止文件 IPC（ziyanctl/冷测除外：无 ZIYAN_EMBED）
local function embed_hot_ban_color_req()
  return _G.ZIYAN_EMBED and true or false
end

local function defined(n) return type(_G[n]) == "function" end

-- 179：找色/找字/找图共用——切前台后重 sync init 方向并催当前前台帧（禁啃旧缓冲）
local _vision_last_front = nil
local _vision_last_force_t = 0
function M.ensure_foreground_frame()
  -- 181：像素永远跟前台；坐标方向永远钉业务 init（切 SB/最小化也不改 rotate）
  refresh_paths()
  local bid = nil
  if type(_G.frontAppBid) == "function" then
    local ok, v = pcall(_G.frontAppBid)
    if ok and type(v) == "string" and #v > 0 then
      bid = v
    end
  end
  if not bid then
    local f = io.open(VAR .. "/.ziyan_front_bid", "r")
    if f then
      bid = (f:read("*l") or ""):match("%S+")
      f:close()
    end
  end
  -- 每圈轻量重申钉死方向（防文件被旁路写成 0）
  pcall(function()
    if type(_G.ZiYanOrient) == "table" then
      if type(_G.ZiYanOrient.reassert_init_orient) == "function" then
        _G.ZiYanOrient.reassert_init_orient()
      elseif type(_G.ZiYanOrient.soft_sync) == "function" then
        _G.ZiYanOrient.soft_sync()
      end
    end
  end)
  if type(bid) ~= "string" or #bid < 1 then
    return
  end
  if _vision_last_front and _vision_last_front ~= bid then
    local isHome = tostring(bid):lower():find("springboard", 1, true) ~= nil
    -- 只换前台帧 + 重申同一 rotate；禁止 init(0) / 跟桌面竖屏
    pcall(function()
      if type(_G.ZiYanOrient) == "table" and type(_G.ZiYanOrient.sync_game_screen) == "function" then
        local pinned = _G.__ZIYAN_ORIENT
        if type(_G.ZiYanOrient.pinned_orient) == "function" then
          pinned = _G.ZiYanOrient.pinned_orient()
        end
        _G.ZiYanOrient.sync_game_screen(pinned, bid)
      end
    end)
    local now = os.clock() or 0
    -- 195 E3：切前台 force 更钝（对标触动不连环 recap）；ensure 与 invalidate 共用节流
    local gap = isHome and 2.0 or 1.5
    if (now - (_vision_last_force_t or 0)) >= gap then
      _vision_last_force_t = now
      pcall(function()
        local f = io.open(VAR .. "/.ziyan_force_recap", "w")
        if f then
          f:write("1\n")
          f:close()
        end
      end)
    end
  end
  _vision_last_front = bid
end

--- 点表安全编码：禁止走 TE jsonEncode（纯哈希表 #t==0 会被编成 []）
local function encode_points_json(pts)
  local parts = {}
  for i = 1, #pts do
    local p = pts[i]
    -- 用数组形式 [[c,dx,dy,b],...]，偏色保留且任意 JSON 库都能编
    parts[#parts + 1] = string.format(
      "[%d,%d,%d,%d]",
      tonumber(p.c) or 0,
      tonumber(p.dx) or 0,
      tonumber(p.dy) or 0,
      tonumber(p.b) or 0
    )
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function encode_flat_json(flat)
  local parts = {}
  for i = 1, #flat do
    parts[#parts + 1] = tostring(math.floor(tonumber(flat[i]) or 0))
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function json_encode_payload(t)
  if type(t) == "table" and type(t[1]) == "table" then
    if t[1].c ~= nil then
      return encode_points_json(t)
    end
    -- 已是 [[c,dx,dy,b],...]
    if type(t[1][1]) == "number" or tonumber(t[1][1]) then
      local parts = {}
      for i = 1, #t do
        local a = t[i]
        parts[#parts + 1] = string.format(
          "[%d,%d,%d,%d]",
          tonumber(a[1]) or 0,
          tonumber(a[2]) or 0,
          tonumber(a[3]) or 0,
          tonumber(a[4]) or 0
        )
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
  end
  if type(t) == "table" then
    return encode_flat_json(t)
  end
  error("unsupported findMulti payload")
end

local function json_decode(s)
  if type(s) ~= "string" or s == "" or not s:find("%S") then
    return nil
  end
  if type(jsonDecode) == "function" then
    local ok, obj = pcall(jsonDecode, s)
    if ok then return obj end
    return nil
  end
  local ok, json = pcall(require, "json")
  if ok and json and json.decode then
    local dok, obj = pcall(json.decode, s)
    if dok then return obj end
  end
  return nil
end

--- 原子写 color_req：避免 io.open("w") 先截断为空时被 SB 轮询删掉（iOS16 rootless 高发）
--- 193 E1：embed 会话内一律拒绝（防热路径回落文件 IPC）
local function write_color_req(payload)
  if embed_hot_ban_color_req() then
    return false
  end
  refresh_paths()
  local tmp = COLOR_REQ .. ".tmp." .. tostring(math.floor((os.clock() or 0) * 1e6) % 1e8)
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(payload)
  f:close()
  pcall(os.remove, COLOR_REQ)
  local ok = os.rename(tmp, COLOR_REQ)
  if not ok then
    -- rename 失败时回退直接写（仍优于空截断窗口）
    f = io.open(COLOR_REQ, "w")
    if not f then
      pcall(os.remove, tmp)
      return false
    end
    f:write(payload)
    f:close()
    pcall(os.remove, tmp)
  end
  return true
end

local function parse_color_token(tok)
  if tok == nil then return 0, 0 end
  if type(tok) == "number" then
    return math.floor(tok) % 0x1000000, 0
  end
  local s = tostring(tok):gsub("%s+", "")
  if s == "" then return 0, 0 end
  -- TS 偏色："0xffffff-101010"
  local bias = 0
  local dash = s:find("-", 2, true)
  if dash then
    local biasStr = s:sub(dash + 1)
    s = s:sub(1, dash - 1)
    if biasStr:lower():match("^0x") then
      bias = (tonumber(biasStr) or 0) % 0x1000000
    elseif biasStr:match("^[0-9A-Fa-f]+$") then
      bias = (tonumber(biasStr, 16) or 0) % 0x1000000
    else
      bias = (tonumber(biasStr) or 0) % 0x1000000
    end
  end
  local c = 0
  if s:match("^[0-9]+$") then
    c = tonumber(s) % 0x1000000
  elseif s:lower():match("^0x") then
    c = (tonumber(s) or 0) % 0x1000000
  elseif s:match("^[0-9A-Fa-f]+$") then
    c = (tonumber(s, 16) or 0) % 0x1000000
  else
    c = tonumber(s) or 0
  end
  return c, bias
end

--- TS → [{c,dx,dy,b}, ...]（含偏色）
function M.ts_to_points(main, offsetStr)
  local c0, b0 = parse_color_token(main)
  local pts = { { c = c0, dx = 0, dy = 0, b = b0 } }
  if type(offsetStr) ~= "string" or offsetStr == "" then
    return pts
  end
  for part in string.gmatch(offsetStr, "[^,]+") do
    local dx, dy, col = string.match(part, "([^|]+)|([^|]+)|([^|]+)")
    if dx then
      local c, b = parse_color_token(col)
      pts[#pts + 1] = {
        c = c,
        dx = tonumber(dx) or 0,
        dy = tonumber(dy) or 0,
        b = b,
      }
    end
  end
  return pts
end

--- 兼容旧名：扁平数字表（无偏色）
function M.ts_to_flat(main, offsetStr)
  local pts = M.ts_to_points(main, offsetStr)
  local flat = { pts[1].c }
  for i = 2, #pts do
    flat[#flat + 1] = pts[i].dx
    flat[#flat + 1] = pts[i].dy
    flat[#flat + 1] = pts[i].c
  end
  return flat
end

-- R8修正：递增计数器 + 时间戳，避免 os.clock nonce 碰撞导致 wait_rep 误读旧回复
local _nonce_seq = 0
local function nonce()
  _nonce_seq = (_nonce_seq + 1) % 100000000
  return "z" .. tostring(_nonce_seq) .. "_" .. tostring(os.time() or 0)
end

local function wait_rep(want_nonce, timeout_s)
  -- 8-156 / 8-161-59：os.clock 截止；默认 0.4s（触动 find 圈常 <150ms）
  timeout_s = tonumber(timeout_s) or 0.4
  local deadline = (os.clock() or 0) + math.max(0.02, timeout_s)
  local spins = 0
  while (os.clock() or 0) <= deadline do
    local f = io.open(COLOR_REP, "r")
    if f then
      local body = f:read("*a") or ""
      f:close()
      local lines = {}
      for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
        lines[#lines + 1] = line
      end
      if #lines >= 2 and lines[1] == want_nonce then
        pcall(os.remove, COLOR_REP)
        local ok = (lines[2] == "ok")
        local payload = lines[3] or ""
        return ok, payload
      end
    end
    spins = spins + 1
    -- 前 40 次纯自旋（~亚 ms）；其后 1ms 原生睡，对齐触动热轮询
    if spins > 40 then
      local raw = _G.__ZIYAN_NATIVE_MSLEEP or _G.__ZIYAN_RAW_MSLEEP
      if type(raw) == "function" then
        pcall(raw, 1)
      elseif type(mSleep) == "function" then
        pcall(mSleep, 1)
      end
    end
  end
  return false, nil
end

--- 调 ScreenBridge；pts 为 [{c,dx,dy,b},...] 或旧扁平数字表
function M.find_multi_flat(flat, fuzzy, x1, y1, x2, y2)
  if type(flat) ~= "table" or #flat < 1 then
    return -1, -1
  end
  refresh_paths()

  -- 8-161-57 / 193 E1：embed → 进程内找色；失败也不回落 color_req
  if _G.ZIYAN_EMBED then
    _ps_embed_find = _ps_embed_find + 1
    if (_ps_embed_find % 20) == 0 then flush_path_stats(false) end
    if type(_G.ziyan_embed_find_multi) ~= "function" then
      flush_path_stats(true)
      return -1, -1
    end
    local ok, vx, vy = pcall(_G.ziyan_embed_find_multi, json_encode_payload(flat),
      fuzzy or 90, x1 or 0, y1 or 0, x2 or -1, y2 or -1)
    if ok and tonumber(vx) and vx >= 0 then
      return tonumber(vx), tonumber(vy)
    end
    return -1, -1
  end

  local n = nonce()
  local payload = table.concat({
    "findMulti",
    json_encode_payload(flat),
    tostring(fuzzy or 90),
    tostring(x1 or 0),
    tostring(y1 or 0),
    tostring(x2 or -1),
    tostring(y2 or -1),
    n,
  }, "\n") .. "\n"

  pcall(os.remove, COLOR_REP)
  -- 冷路径（独立 lua / ziyanctl）：文件 IPC；embed 已被 write_color_req 拒绝
  _ps_color_req_find = _ps_color_req_find + 1
  if (_ps_color_req_find % 10) == 0 then flush_path_stats(false) end
  if not write_color_req(payload) then
    return -1, -1
  end

  -- 8-161-74：锁帧热路径应答应 <50ms；0.25s 超时够用（触动圈节奏）
  local ok, body = wait_rep(n, 0.25)
  if not ok or not body or body == "" then
    return -1, -1
  end
  local obj = json_decode(body)
  -- R8: 采样写入 coord_diag（每 20 次命中写 1 次），降低 disk writes
  local _diag_skip = 0
  local function diag_hit(vx, vy, sw, sh)
    _diag_skip = _diag_skip + 1
    if _diag_skip < 20 then return end
    _diag_skip = 0
    pcall(function()
      local D = _G.ZiYanCoordDiag
      if not D then
        D = dofile((_G.ZIYAN_LUA or "/usr/lib/ziyan/lib/lua") .. "/ziyan_engine/coord_diag.lua")
        if type(D) == "table" and D.install then D.install() end
      end
      if D and D.write_find then
        D.write_find(vx, vy, sw, sh)
      end
    end)
  end
  if type(obj) == "table" and obj.ok and tonumber(obj.x) and obj.x >= 0 then
    local vx, vy = tonumber(obj.x), tonumber(obj.y)
    diag_hit(vx, vy, obj.w, obj.h)
    return vx, vy
  end
  if type(obj) == "table" and obj[1] and type(obj[1]) == "table" then
    local p = obj[1]
    if tonumber(p.x) and p.x >= 0 then
      local vx, vy = tonumber(p.x), tonumber(p.y)
      diag_hit(vx, vy, obj.w or p.w, obj.h or p.h)
      return vx, vy
    end
  end
  return -1, -1
end

function M.get_color(x, y)
  if _G.ZIYAN_EMBED then
    _ps_embed_get = _ps_embed_get + 1
    if (_ps_embed_get % 20) == 0 then flush_path_stats(false) end
    if type(_G.ziyan_embed_get_color) ~= "function" then
      return -1
    end
    local ok, c = pcall(_G.ziyan_embed_get_color, x or 0, y or 0)
    if ok and tonumber(c) and c >= 0 then
      return math.floor(tonumber(c)) % 0x1000000
    end
    return -1
  end
  _ps_color_req_get = _ps_color_req_get + 1
  local n = nonce()
  local payload = table.concat({
    "getColor",
    tostring(x or 0),
    tostring(y or 0),
    n,
  }, "\n") .. "\n"
  pcall(os.remove, COLOR_REP)
  if not write_color_req(payload) then return -1 end
  -- USB 开/关游压力下偶发超时：加长等待并重试一次
  local ok, body = wait_rep(n, 2.5)
  if not ok then
    pcall(os.remove, COLOR_REQ)
    pcall(os.remove, COLOR_REP)
    n = nonce()
    payload = table.concat({
      "getColor", tostring(x or 0), tostring(y or 0), n,
    }, "\n") .. "\n"
    if not write_color_req(payload) then return -1 end
    ok, body = wait_rep(n, 2.5)
  end
  if not ok then return -1 end
  local c = tonumber(body)
  if c == nil then return -1 end
  c = math.floor(c) % 0x1000000
  if c < 0 then return -1 end
  return c
end

--- TSColorPicker / 触动：区域 0,0,0,0 表示全屏（与 x2/y2=-1 等价）
local function normalize_region(x1, y1, x2, y2)
  x1 = tonumber(x1) or 0
  y1 = tonumber(y1) or 0
  x2 = tonumber(x2)
  y2 = tonumber(y2)
  if x2 == nil then x2 = -1 end
  if y2 == nil then y2 = -1 end
  if x1 == 0 and y1 == 0 and x2 == 0 and y2 == 0 then
    return 0, 0, -1, -1
  end
  return x1, y1, x2, y2
end

--- 模板找图：path 为 PNG；返回逻辑坐标左上角
function M.find_image(path, fuzzy, x1, y1, x2, y2)
  if type(path) ~= "string" or path == "" then
    return -1, -1
  end
  M.ensure_foreground_frame()
  x1, y1, x2, y2 = normalize_region(x1, y1, x2, y2)
  local n = nonce()
  local payload = table.concat({
    "findImage",
    path,
    tostring(fuzzy or 80),
    tostring(x1 or 0),
    tostring(y1 or 0),
    tostring(x2 or -1),
    tostring(y2 or -1),
    n,
  }, "\n") .. "\n"
  pcall(os.remove, COLOR_REP)
  if not write_color_req(payload) then
    return -1, -1
  end
  local ok, body = wait_rep(n, 8.0)
  if not ok or not body or body == "" then
    return -1, -1
  end
  local obj = json_decode(body)
  if type(obj) == "table" and obj.ok and tonumber(obj.x) and obj.x >= 0 then
    return tonumber(obj.x), tonumber(obj.y)
  end
  return -1, -1
end

--- 截屏到逻辑方向 PNG（OCR / TSColorPicker）
-- path 可选，默认 ZYCV/.ziyan_cv_shot.png（用户可读写目录）
function M.dump_screen(path)
  M.ensure_foreground_frame()
  local dest = path
  if type(dest) ~= "string" or dest == "" then
    local zycv = (type(_G.ZIYAN_ZYCV) == "string" and _G.ZIYAN_ZYCV ~= "" and _G.ZIYAN_ZYCV)
      or "/private/var/mobile/Media/ZiYan/ZYCV"
    dest = zycv .. "/.ziyan_cv_shot.png"
  end
  local n = nonce()
  local payload = table.concat({
    "dumpScreen",
    dest,
    n,
  }, "\n") .. "\n"
  pcall(os.remove, COLOR_REP)
  if not write_color_req(payload) then return nil end
  local ok, body = wait_rep(n, 5.0)
  local function sized(p)
    if type(p) ~= "string" or p == "" then return 0 end
    local rf = io.open(p, "rb")
    if not rf then return 0 end
    local sz = rf:seek("end") or 0
    rf:close()
    return tonumber(sz) or 0
  end
  if ok and body and body ~= "" and body ~= "dump failed" and sized(body) > 100 then
    return body
  end
  -- 回执偶发超时：仅当目标路径已写出才算成功（勿回落陈旧 ts_shot → 假 true）
  if sized(dest) > 100 then return dest end
  return nil
end

--- SpringBoard Vision OCR（USB iOS16 必需；LAN 作 CLI 回退）
function M.ocr_region(x, y, x1, y1)
  refresh_paths()
  M.ensure_foreground_frame()
  x = math.floor(tonumber(x) or 0)
  y = math.floor(tonumber(y) or 0)
  x1 = math.floor(tonumber(x1) or 0)
  y1 = math.floor(tonumber(y1) or 0)
  -- 0,0,-1,-1 全屏：读 .ziyan_orient 逻辑尺寸展开，避免 SB 旧逻辑把 -1 夹成 1px
  if x1 < 0 or y1 < 0 then
    local ow, oh = 0, 0
    local of = io.open(VAR .. "/.ziyan_orient", "r")
    if of then
      of:read("*l")
      ow = tonumber(of:read("*l") or "") or 0
      oh = tonumber(of:read("*l") or "") or 0
      of:close()
    end
    if ow < 2 or oh < 2 then
      ow, oh = 2208, 1242
    end
    if x1 < 0 then x1 = ow - 1 end
    if y1 < 0 then y1 = oh - 1 end
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
  end
  local n = nonce()
  local payload = table.concat({
    "ocr",
    tostring(x),
    tostring(y),
    tostring(x1),
    tostring(y1),
    n,
  }, "\n") .. "\n"
  pcall(os.remove, COLOR_REP)
  if not write_color_req(payload) then
    return { ok = false, text = "", error = "no_req", via = "sb_ocr" }
  end
  -- 8-161-99：桌面 Vision 偶慢；3.5s（仍远低于旧 8s，避免卡死循环）
  local ok, body = wait_rep(n, 3.5)
  if not ok or not body or body == "" then
    return { ok = false, text = "", error = "timeout", via = "sb_ocr" }
  end
  local obj = json_decode(body)
  if type(obj) ~= "table" then
    return { ok = false, text = "", error = "bad_json", via = "sb_ocr", raw = body }
  end
  if obj.text == nil then obj.text = "" end
  local trimmed = tostring(obj.text):gsub("^%s+", ""):gsub("%s+$", "")
  obj.text = trimmed
  -- 空字一律 ok=false，避免上层把 "" 当成功
  obj.ok = (trimmed ~= "") and (obj.ok ~= false)
  if trimmed == "" and (not obj.error or obj.error == "") then
    obj.error = "empty_text"
  end
  obj.via = obj.via or "sb_ocr"
  return obj
end

--- 对已有 PNG 二次 Vision（临时图重试）
function M.ocr_file(path)
  refresh_paths()
  if type(path) ~= "string" or path == "" then
    return { ok = false, text = "", error = "no_path", via = "sb_ocr_file" }
  end
  local n = nonce()
  local payload = table.concat({ "ocrFile", path, n }, "\n") .. "\n"
  pcall(os.remove, COLOR_REP)
  if not write_color_req(payload) then
    return { ok = false, text = "", error = "no_req", via = "sb_ocr_file" }
  end
  local ok, body = wait_rep(n, 8.0)
  if not ok or not body or body == "" then
    return { ok = false, text = "", error = "timeout", via = "sb_ocr_file" }
  end
  local obj = json_decode(body)
  if type(obj) ~= "table" then
    return { ok = false, text = "", error = "bad_json", via = "sb_ocr_file" }
  end
  if obj.text == nil then obj.text = "" end
  obj.ok = obj.ok ~= false
  obj.via = obj.via or "sb_ocr_file"
  return obj
end

--- 触动/TS API
function M.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
  if type(b) == "string" then
    local pts = M.ts_to_points(a, b)
    local x1, y1, x2, y2 = normalize_region(d, e, f, g)
    return M.find_multi_flat(pts, c or 90, x1, y1, x2, y2)
  end
  -- TE 扁平表或点表
  local flat = a
  if type(a) == "table" and type(a[1]) == "table" then
    if a[1].c ~= nil then
      flat = a
    else
      flat = {}
      for i, item in ipairs(a) do
        if i == 1 then
          local c0, b0 = parse_color_token(item[1])
          flat[1] = { c = c0, dx = 0, dy = 0, b = b0 }
        else
          local c0, b0 = parse_color_token(item[1])
          flat[#flat + 1] = {
            c = c0,
            dx = tonumber(item[2]) or 0,
            dy = tonumber(item[3]) or 0,
            b = b0,
          }
        end
      end
    end
  end
  return M.find_multi_flat(flat, b or 90, c or 0, d or 0, e or -1, f or -1)
end

local function ipc_keep_screen(on)
  -- 8-161-57 / 193 E1：embed 进程内 keep；失败不回落 color_req
  if _G.ZIYAN_EMBED then
    _ps_embed_keep = _ps_embed_keep + 1
    flush_path_stats(false)
    if type(_G.ziyan_embed_keep_screen) ~= "function" then
      return false
    end
    local ok = pcall(_G.ziyan_embed_keep_screen, on and true or false)
    return ok and true or false
  end
  -- 8-161-53：daemon 旗已在 → 信任，免重复 IPC（根治 keep 风暴）
  if on then
    local kd = io.open(VAR .. "/.ziyan_keep_daemon", "r")
    if kd then
      kd:close()
      return true
    end
  end
  _ps_color_req_keep = _ps_color_req_keep + 1
  local n = nonce()
  local payload = table.concat({
    "keepScreen",
    on and "1" or "0",
    n,
  }, "\n") .. "\n"
  pcall(os.remove, COLOR_REP)
  if not write_color_req(payload) then
    return false
  end
  -- keep 应答应极快（daemon 先答后截）；0.6s 足够
  local ok, body = wait_rep(n, 0.6)
  if ok and body then
    return body == "1"
  end
  -- 超时但 daemon 旗已落下 → 仍视为成功（应答竞态）
  if on then
    local kd2 = io.open(VAR .. "/.ziyan_keep_daemon", "r")
    if kd2 then
      kd2:close()
      return true
    end
  end
  return false
end

function M.install()
  refresh_paths()
  _G.ZiYanCV_Native = M

  if not _G.__ZIYAN_KEEP_SCREEN_FUNC then
    _G.__ZIYAN_KEEP_SCREEN_FUNC = true
    function keepScreen(on)
      local want = on and true or false
      local ok = ipc_keep_screen(want)
      -- R8修正：IPC 失败时返回 false 并标记未启用（原 return want 导致 ensure 误认为成功）
      if not ok then
        _G.__ZIYAN_KEEP_SCREEN = false
        _G.__ZIYAN_KEEP_EXPLICIT = false
        return false
      end
      _G.__ZIYAN_KEEP_SCREEN = want
      -- 8-137：脚本显式 keepScreen → 真锁帧直至 false（自动 keep 不置此旗）
      if want then
        _G.__ZIYAN_KEEP_EXPLICIT = true
      else
        _G.__ZIYAN_KEEP_EXPLICIT = false
        -- 8-161-95：对照触动 keep(false) 释缓冲 → 通知 SB 释堆（shm 由 framecap 延迟清）
        pcall(function()
          local f = io.open(VAR .. "/.ziyan_release_screen", "w")
          if f then f:write("1\n"); f:close() end
        end)
      end
      return true
    end
    function isKeepScreen()
      -- 阶段4：以 framecap locked_seq / keep_daemon 为唯一真相
      local kd = io.open(VAR .. "/.ziyan_keep_daemon", "r")
      if kd then
        kd:close()
        _G.__ZIYAN_KEEP_SCREEN = true
        return true
      end
      _G.__ZIYAN_KEEP_SCREEN = false
      return false
    end
  end

  -- R8 / 8-161-52：auto-keep 批从 0.35s→8s（对齐触动锁帧：循环内共帧，禁 keep 狂切）
  -- 切前后台由 front_bid 变化主动 invalidate，不再靠 350ms 释帧「跟手」
  local _prev_tap = tap
  local _find_call_count = 0
  local _find_total_cpu_ms = 0
  local _find_total_ipc_ms = 0
  local _find_batch_start_wall = os.time()
  local _find_batch_count = 0
  local _auto_keep_batch_t0 = 0 -- os.clock 批起点
  local AUTO_KEEP_BATCH_SEC = 8.0
  local _last_front_bid = nil
  local _last_force_recap_t = 0 -- 8-161-95：force_recap 节流（对标触动不狂重截）

  local _last_keep_screen_sync = 0
  -- R8.1：读 SB 侧 keepScreen 实况（mem_pulse / find_perf），防 Lua 标志与 SB 脱节
  local function sb_keep_screen_off()
    local paths = {
      VAR .. "/.ziyan_sb_find_perf",
      VAR .. "/.ziyan_sb_mem_pulse",
    }
    for _, p in ipairs(paths) do
      local f = io.open(p, "r")
      if f then
        local body = f:read("*a") or ""
        f:close()
        if body:find("keepScreen=0", 1, true) then
          return true
        end
        if body:find("keepScreen=1", 1, true) then
          return false
        end
      end
    end
    return nil -- 未知
  end
  local function invalidate_keep_screen()
    -- 阶段4：切前台废锁 → 走统一 keep(false)；禁只删文件留下 locked_seq 幽灵
    _G.__ZIYAN_KEEP_SCREEN = false
    _G.__ZIYAN_KEEP_EXPLICIT = false
    if _G.ZIYAN_EMBED and type(_G.ziyan_embed_keep_screen) == "function" then
      pcall(_G.ziyan_embed_keep_screen, false)
    else
      pcall(function()
        local n = nonce()
        local payload = table.concat({ "keepScreen", "0", n }, "\n") .. "\n"
        write_color_req(payload)
      end)
    end
    _auto_keep_batch_t0 = 0
  end
  -- 8-161-52/54：前台 bundle 变化 → 催重截；**禁止拆 keep**
  -- （旧：invalidate keep0/1 + daemon clear_shm → Home 切回卡十几秒）
  local function invalidate_keep_if_front_changed()
    local bid = nil
    if type(_G.frontAppBid) == "function" then
      local ok, v = pcall(_G.frontAppBid)
      if ok and type(v) == "string" and #v > 0 then
        bid = v
      end
    end
    if not bid then
      local f = io.open(VAR .. "/.ziyan_front_bid", "r")
      if f then
        bid = (f:read("*l") or ""):match("%S+")
        f:close()
      end
    end
    if type(bid) ~= "string" or #bid < 1 then
      return
    end
    if _last_front_bid and _last_front_bid ~= bid then
      local low = tostring(bid):lower()
      local isHome = low:find("springboard", 1, true) ~= nil
      -- 181：切前台只换帧；方向钉业务 init（禁止重放成别的 rotate / init(0)）
      pcall(function()
        if type(_G.ZiYanOrient) == "table" and type(_G.ZiYanOrient.sync_game_screen) == "function" then
          local pinned = _G.__ZIYAN_ORIENT
          if type(_G.ZiYanOrient.pinned_orient) == "function" then
            pinned = _G.ZiYanOrient.pinned_orient()
          end
          _G.ZiYanOrient.sync_game_screen(pinned, bid)
        elseif type(_G.ZiYanOrient) == "table" and type(_G.ZiYanOrient.reassert_init_orient) == "function" then
          _G.ZiYanOrient.reassert_init_orient()
        end
      end)
      -- 195 E3：切前台只换帧；force 由 ensure_foreground_frame 统一写（禁双写+禁 toast_bump 风暴）
      -- 对标触动：找色跟前台像素，不靠 toast 刷屏催帧
      do
        local now = os.clock() or 0
        local gap = isHome and 2.0 or 1.5
        -- 与 ensure_foreground_frame 共用 _last_force_recap_t；若 ensure 已写则跳过
        if (now - (_last_force_recap_t or 0)) >= gap and
           (now - (_vision_last_force_t or 0)) >= gap then
          _last_force_recap_t = now
          _vision_last_force_t = now
          pcall(function()
            local f = io.open(VAR .. "/.ziyan_force_recap", "w")
            if f then
              f:write("1\n")
              f:close()
            end
          end)
        end
      end
    end
    _last_front_bid = bid
  end
  local function ensure_keep_screen_on()
    -- 191：回滚 190 会话默认 auto-keep（miss 死循环 + KeepEnable → 内存/SB 崩）
    -- 对齐触动：仅脚本显式 keepScreen(true)，或机上触碰 `.ziyan_auto_keep` 才补锁
    -- 像素仍永远跟前台（ensure_foreground_frame）；禁「有会话就狂 keep」
    do
      local nokeep = io.open(VAR .. "/.ziyan_no_auto_keep", "r")
      if nokeep then nokeep:close(); return end
    end
    local allow_auto = false
    do
      local fa = io.open(VAR .. "/.ziyan_auto_keep", "r")
      if fa then fa:close(); allow_auto = true end
    end
    -- 显式 keep：只维持标志/daemon 已锁，不再每圈 ipc_keep(true)
    if _G.__ZIYAN_KEEP_EXPLICIT == true then
      local kd = io.open(VAR .. "/.ziyan_keep_daemon", "r")
      if kd then
        kd:close()
        _G.__ZIYAN_KEEP_SCREEN = true
        return
      end
      -- 显式但 daemon 掉锁：补一次（节流）
      local now = os.time() or 0
      if (now - (_last_keep_screen_sync or 0)) < 2 then
        return
      end
      pcall(function()
        if type(ipc_keep_screen) == "function" and ipc_keep_screen(true) then
          _G.__ZIYAN_KEEP_SCREEN = true
          _last_keep_screen_sync = now
        end
      end)
      return
    end
    if not allow_auto then
      return
    end
    if _G.__ZIYAN_KEEP_SCREEN == true then
      local kd0 = io.open(VAR .. "/.ziyan_keep_daemon", "r")
      if kd0 then
        kd0:close()
        return
      end
    end
    local kd = io.open(VAR .. "/.ziyan_keep_daemon", "r")
    if kd then
      kd:close()
      _G.__ZIYAN_KEEP_SCREEN = true
      if _auto_keep_batch_t0 <= 0 then
        _auto_keep_batch_t0 = os.clock() or 0
      end
      return
    end
    local nowc = os.clock() or 0
    if _G.__ZIYAN_KEEP_SCREEN == true and _G.__ZIYAN_KEEP_EXPLICIT ~= true
        and _auto_keep_batch_t0 > 0
        and (nowc - _auto_keep_batch_t0) >= AUTO_KEEP_BATCH_SEC then
      _auto_keep_batch_t0 = nowc
    end
    local now = os.time() or 0
    if (now - (_last_keep_screen_sync or 0)) < 2 then
      return
    end
    pcall(function()
      if type(ipc_keep_screen) == "function" then
        local ok = ipc_keep_screen(true)
        if ok then
          _G.__ZIYAN_KEEP_SCREEN = true
          _G.__ZIYAN_KEEP_EXPLICIT = false
          _auto_keep_batch_t0 = os.clock() or 0
          _last_keep_screen_sync = now
        end
      end
    end)
  end
  -- 8-161-53：对齐触动 cycle CSV，供门禁「圈稳 / gap>2.5s=0」
  local _cycle_last_c = nil
  local function append_cycle_csv(find_ms, x, y)
    pcall(function()
      local path = VAR .. "/.ziyan_ts_cycle.csv"
      local cnow = (os.clock() or 0) * 1000
      local cycle_ms = 0
      if _cycle_last_c then
        cycle_ms = cnow - _cycle_last_c
      end
      _cycle_last_c = cnow
      local bid = _last_front_bid or ""
      local hit = (tonumber(x) and x >= 0) and 1 or 0
      local af = io.open(path, "a")
      if not af then
        af = io.open(path, "w")
        if af then
          af:write("wall_ms,find_ms,cycle_ms,x,y,hit,front_bid\n")
        end
      end
      if af then
        -- 132：对标触动无历史找色落盘；64KB 即截断（旧 800KB 会一直涨）
        local sz = af:seek("end") or 0
        if sz > 65536 then
          af:close()
          af = io.open(path, "w")
          if af then
            af:write("wall_ms,find_ms,cycle_ms,x,y,hit,front_bid\n")
          end
        end
      end
      if af then
        af:write(string.format("%.0f,%.2f,%.2f,%d,%d,%d,%s\n",
          (os.time() or 0) * 1000, find_ms or 0, cycle_ms, x or -1, y or -1, hit, bid))
        af:close()
      end
    end)
  end
  -- 8-161-80：找色热路径禁止 open_app / 进程拉起；进游只靠本脚本 find+tap
  -- （Desktop ios7/ios8p 只采游戏内色点；关进程后需脚本自备桌面图标找色）
  local function ensure_target_bid_file()
    local tf = io.open(VAR .. "/.ziyan_target_bid", "r")
    if tf then
      local bid = (tf:read("*l") or ""):match("%S+")
      tf:close()
      if type(bid) == "string" and #bid > 3 and not bid:find("springboard", 1, true) then
        return
      end
    end
    local intent = ""
    local inf = io.open(VAR .. "/.ziyan_run_intent", "r")
    if inf then intent = inf:read("*a") or ""; inf:close() end
    local bid = nil
    if intent:find("ios8p", 1, true) then
      bid = "com.ljzbbadao.game"
    elseif intent:find("ios7", 1, true) then
      bid = "com.xztl.ios"
    end
    if type(bid) == "string" then
      pcall(function()
        local w = io.open(VAR .. "/.ziyan_target_bid", "w")
        if w then w:write(bid .. "\n"); w:close() end
      end)
    end
  end

  -- 192：连续 miss 熔断——有 keep/会话时超窗拆 keep，防色点不对空转拖垮 SB
  local _miss_fuse_t0 = 0
  local _miss_fuse_fired = false
  local MISS_FUSE_SEC = 120
  local function maybe_miss_fuse(hit)
    if hit then
      _miss_fuse_t0 = 0
      _miss_fuse_fired = false
      return
    end
    local now = os.time() or 0
    if _miss_fuse_t0 <= 0 then
      _miss_fuse_t0 = now
      return
    end
    if _miss_fuse_fired then
      return
    end
    if (now - _miss_fuse_t0) < MISS_FUSE_SEC then
      return
    end
    local has_sess = false
    do
      local s = io.open(VAR .. "/.ziyan_active", "r")
        or io.open(VAR .. "/.ziyan_script_session", "r")
      if s then s:close(); has_sess = true end
    end
    local keep = (_G.__ZIYAN_KEEP_SCREEN == true)
    if not keep then
      local kd = io.open(VAR .. "/.ziyan_keep_daemon", "r")
      if kd then kd:close(); keep = true end
    end
    if not keep and not has_sess then
      return
    end
    _miss_fuse_fired = true
    pcall(invalidate_keep_screen)
    pcall(function()
      local f = io.open(VAR .. "/.ziyan_miss_fuse", "w")
      if f then
        f:write(string.format("ts=%d miss_sec=%d keep_was=1\n", now, now - _miss_fuse_t0))
        f:close()
      end
    end)
    pcall(function()
      if type(_G.toast) == "function" then
        _G.toast("miss fuse: keep off", 2)
      end
    end)
  end

  function findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
    if type(_G.__ZIYAN_wait_while_paused) == "function" then
      _G.__ZIYAN_wait_while_paused()
    end
    -- 179：与找图/OCR 共用前台同步（invalidate_keep 保留兼容）
    M.ensure_foreground_frame()
    invalidate_keep_if_front_changed()
    ensure_target_bid_file()
    -- auto-keepScreen：确保 find 前缓存已启用（首次 find 或 tap 后重新启用）
    ensure_keep_screen_on()
    local _t0 = os.clock()
    local rx, ry = M.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
    maybe_miss_fuse(tonumber(rx) and rx >= 0)
    local _cpu_elapsed = (os.clock() - _t0) * 1000
    append_cycle_csv(_cpu_elapsed, rx, ry)
    _find_call_count = _find_call_count + 1
    _find_total_cpu_ms = _find_total_cpu_ms + _cpu_elapsed
    -- 8-118：用 os.clock 累计单次 IPC 墙钟，避免 os.time 批跨 sleep 把 avg_wall 抬到 650～950
    _find_total_ipc_ms = (_find_total_ipc_ms or 0) + _cpu_elapsed
    _find_batch_count = _find_batch_count + 1
    -- 8-140/97：每 20 次或 ≥10s 写 color_perf + find_pulse（防误判 hung/stale）
    _find_last_perf_write = _find_last_perf_write or 0
    local _now_wall = os.time() or 0
    if _find_batch_count >= 20 or (_now_wall - _find_last_perf_write) >= 10 then
      local avg_ipc_ms = 0
      if _find_batch_count > 0 then
        avg_ipc_ms = _find_total_ipc_ms / _find_batch_count
      end
      local avg_cpu_ms = _find_total_cpu_ms / math.max(1, _find_call_count)
      pcall(function()
        local f = io.open(VAR .. "/.ziyan_color_perf", "w")
        if f then
          f:write(string.format(
            "calls=%d avg_wall_ms=%.1f avg_cpu_ms=%.1f last_cpu_ms=%.1f keepScreen=%s\n",
            _find_call_count, avg_ipc_ms, avg_cpu_ms, _cpu_elapsed,
            tostring(_G.__ZIYAN_KEEP_SCREEN == true)))
          f:close()
        end
        -- 独立脉冲：即使 color_perf 被其它组件覆盖，mtime 仍证明热找色
        local p = io.open(VAR .. "/.ziyan_find_pulse", "w")
        if p then
          p:write(string.format("ts=%d n=%d\n", _now_wall, _find_call_count))
          p:close()
        end
        flush_path_stats(true)
      end)
      _find_last_perf_write = _now_wall
      if _find_batch_count >= 20 then
        _find_batch_count = 0
        _find_total_ipc_ms = 0
        _find_batch_start_wall = os.time()
      end
    end
    return rx, ry
  end

  function findMultiColor(a, b, c, d, e, f, g)
    return findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
  end

  -- 8-161-74：对齐触动 — tap 不拆 keep（旧每 tap keep0→清帧/重截 → 找色超级慢）
  -- 仅在非显式锁帧时轻推 force，让下一圈可吃新画面
  if type(_prev_tap) == "function" and not _G.__ZIYAN_TAP_WRAPPED then
    _G.__ZIYAN_TAP_WRAPPED = true
    function tap(a, b, c, d)
      local ok = _prev_tap(a, b, c, d)
      -- 8-161-76：tap 后也不写 force（防与合帧/拉回叠成风暴）；靠 keep 批超时换帧
      return ok
    end
  end

  -- 触动习惯：findImage* 返回逻辑左上角；miss → -1,-1
  -- 签名对齐公开 API：findImage(path[, fuzzy]) / findImageInRegionFuzzy(path, fuzzy, x1,y1,x2,y2)
  function findImage(path, fuzzy)
    return M.find_image(path, fuzzy or 80, 0, 0, -1, -1)
  end

  function findImageFuzzy(path, fuzzy)
    return M.find_image(path, fuzzy or 80, 0, 0, -1, -1)
  end

  function findImageInRegion(path, x1, y1, x2, y2)
    return M.find_image(path, 80, x1, y1, x2, y2)
  end

  function findImageInRegionFuzzy(path, fuzzy, x1, y1, x2, y2)
    return M.find_image(path, fuzzy or 80, x1, y1, x2, y2)
  end

  function dumpScreen(path)
    return M.dump_screen(path)
  end

  -- 可选：原生 getColor 优先（ScreenBridge）
  if not _G.__ZIYAN_CV_GETCOLOR then
    _G.__ZIYAN_CV_GETCOLOR = true
    local prev = getColor
    function getColor(x, y)
      -- 190：取色同找色——跟前台 + 会话 keep
      M.ensure_foreground_frame()
      ensure_keep_screen_on()
      local c = M.get_color(x, y)
      if c and c >= 0 then return c end
      if type(prev) == "function" then return prev(x, y) end
      return -1
    end
  end

  -- 覆盖占位 snapshot：走 ScreenBridge 真截屏
  function snapshot(path)
    local p = M.dump_screen(path)
    return p ~= nil
  end

  return M
end

return M
