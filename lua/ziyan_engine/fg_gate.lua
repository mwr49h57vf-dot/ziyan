--[[ ForegroundFrameGate — 找色/找图/找字/识字入口
  触动模型：对着当前屏幕像素找色，不看前台是哪个 App。
  本门只重申 init 方向、切屏时催一帧；禁止用 shm_bid/包名判 VISION_STALE 拦住 matcher。
  front_generation：由 framecap 发布 .ziyan_front_generation（禁 Lua 自增假变量）。
]]
local M = { module = "fg_gate", version = "203.1" }

local function resolve_var()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function read_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*l")
  f:close()
  if type(s) ~= "string" then return nil end
  return s:match("%S+")
end

local function write_diag(body)
  pcall(function()
    local f = io.open(resolve_var() .. "/.ziyan_vision_gate", "w")
    if not f then return end
    f:write(body)
    f:close()
  end)
end

local _last_front = nil
local _last_force_t = 0

function M.front_bid()
  if type(_G.frontAppBid) == "function" then
    local ok, v = pcall(_G.frontAppBid)
    if ok and type(v) == "string" and #v > 0 then
      return v
    end
  end
  return read_line(resolve_var() .. "/.ziyan_front_bid")
end

function M.init_orient()
  local o = tonumber(_G.__ZIYAN_ORIENT)
  if not o and type(_G.ZiYanOrient) == "table" and type(_G.ZiYanOrient.pinned_orient) == "function" then
    o = tonumber(_G.ZiYanOrient.pinned_orient())
  end
  o = tonumber(o) or 1
  if o < 0 or o > 2 then o = 1 end
  return o
end

function M.front_generation()
  local g = tonumber(read_line(resolve_var() .. "/.ziyan_front_generation"))
  return g or 0
end

function M.frame_seq()
  local s = read_line(resolve_var() .. "/.ziyan_frame_seq")
      or read_line(resolve_var() .. "/.ziyan_shm_seq")
  return tonumber(s) or 0
end

function M.shm_front_bid()
  return read_line(resolve_var() .. "/.ziyan_shm_front_bid")
end

function M.workset_scale()
  local f = io.open(resolve_var() .. "/.ziyan_workset_meta", "r")
  if not f then return 1 end
  local scale = 1
  for line in f:lines() do
    local s = line:match("^scale=(%d+)")
    if s then scale = tonumber(s) or 1; break end
  end
  f:close()
  if scale < 1 then scale = 1 end
  return scale
end

--- 进入 matcher 前：重申 init、切前台催帧；返回 gate 快照
-- @return ok, snap|{err=}
function M.acquire(kind)
  kind = tostring(kind or "vision")
  local var = resolve_var()
  local bid = M.front_bid()
  local orient = M.init_orient()
  pcall(function()
    if type(_G.ZiYanOrient) == "table" then
      if type(_G.ZiYanOrient.reassert_init_orient) == "function" then
        _G.ZiYanOrient.reassert_init_orient()
      elseif type(_G.ZiYanOrient.soft_sync) == "function" then
        _G.ZiYanOrient.soft_sync()
      end
    end
  end)
  if type(bid) == "string" and #bid > 0 then
    if _last_front and _last_front ~= bid then
      pcall(function()
        if type(_G.ZiYanOrient) == "table" and type(_G.ZiYanOrient.sync_game_screen) == "function" then
          _G.ZiYanOrient.sync_game_screen(orient, bid)
        end
      end)
      local now = os.clock() or 0
      -- 前台切换只代表当前可见帧换代；不按 SpringBoard/业务 App
      -- 选择不同策略。init(0/1/2) 是唯一的逻辑方向来源。
      local gap = 1.5
      if (now - (_last_force_t or 0)) >= gap then
        _last_force_t = now
        pcall(function()
          local f = io.open(var .. "/.ziyan_force_recap", "w")
          if f then f:write("1\n"); f:close() end
        end)
      end
    end
    _last_front = bid
  end
  local shmBid = M.shm_front_bid() or ""
  local seq = M.frame_seq()
  local gen = M.front_generation()
  local snap = {
    kind = kind,
    front_bid = bid or "",
    shm_front_bid = shmBid,
    front_generation = gen,
    init_orient = orient,
    seq = seq,
    workset_scale = M.workset_scale(),
    ok = true,
    err = nil,
  }
  -- 切屏只催帧，不因包名/shm 错位拒绝找色。颜色对上取色器就是命中。
  write_diag(string.format(
    "ts=%d kind=%s ok=%s err=%s front=%s shm=%s gen=%d orient=%d seq=%d scale=%d\n",
    os.time() or 0, kind, tostring(snap.ok), tostring(snap.err or "-"),
    snap.front_bid, snap.shm_front_bid, snap.front_generation, snap.init_orient,
    snap.seq, snap.workset_scale or 1))
  return snap.ok, snap
end

function M.ensure_foreground_frame()
  M.acquire("ensure")
end

return M
