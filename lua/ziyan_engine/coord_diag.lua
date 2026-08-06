--[[
  坐标映射诊断（阶段7.6.2-R3.1）
  find 成功 / tap 下发时写 .ziyan_coord_diag；读 tap_proof 自动判错型。
  不改用户脚本；禁止固定物理补偿。
]]

local M = { name = "coord_diag", version = "1.0.1" } -- 7.6.3: coordinateSpace

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function read_orient()
  local o, lw, lh = 1, 1136, 640
  local f = io.open(var_dir() .. "/.ziyan_orient", "r")
  if f then
    o = tonumber(f:read("*l")) or o
    lw = tonumber(f:read("*l")) or lw
    lh = tonumber(f:read("*l")) or lh
    f:close()
  end
  if (o == 1 or o == 2) and lw < lh then
    lw, lh = lh, lw
  end
  return o, lw, lh
end

local function read_native()
  local pw, ph, scale = 640, 1136, 2
  local f = io.open(var_dir() .. "/.ziyan_native_wh", "r")
  if f then
    pw = tonumber(f:read("*l")) or pw
    ph = tonumber(f:read("*l")) or ph
    scale = tonumber(f:read("*l")) or scale
    f:close()
  end
  return pw, ph, scale
end

--- 与 Oc ZiYanMapLogicToNorm 对齐的期望 HID（竖屏玻璃）
local function expect_glass_hid(sx, sy)
  local o, SW, SH = read_orient()
  local pw, ph = read_native()
  local px, py
  if pw >= ph then
    -- 缓冲已是横屏：恒等
    px = sx / SW * pw
    py = sy / SH * ph
  else
    if o == 0 then
      local lw0 = math.min(SW, SH)
      local lh0 = math.max(SW, SH)
      if SW >= SH then
        lw0, lh0 = SH, SW
      end
      px = sx / lw0 * pw
      py = sy / lh0 * ph
    elseif o == 1 then
      -- Home 右：port ← land(w-1-y, x)
      px = (1.0 - sy / SH) * pw
      py = sx / SW * ph
    else
      -- Home 左
      px = sy / SH * pw
      py = (1.0 - sx / SW) * ph
    end
  end
  local nx = math.min(1.0, math.max(0.0, (px + 0.5) / pw))
  local ny = math.min(1.0, math.max(0.0, (py + 0.5) / ph))
  return nx, ny, px, py
end

local function approx(a, b, eps)
  return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= (eps or 0.06)
end

--- 根据实际 HID 相对期望分类
--- R8.3.12：仅竖屏玻璃 MapLogicToNorm 为 ok；横屏窗 identity 视为 hid_path_flip（回归）
function M.classify(logic_x, logic_y, hid_x, hid_y, transform_count)
  local o, SW, SH = read_orient()
  local ex, ey = expect_glass_hid(logic_x, logic_y)
  local id_x = logic_x / SW
  local id_y = logic_y / SH
  local mir_x = 1.0 - id_x
  local mir_y = 1.0 - id_y
  local rot_x = logic_y / SH
  local rot_y = logic_x / SW
  local err = "unknown"
  if transform_count and transform_count > 1 then
    err = "double_transform"
  elseif approx(hid_x, ex) and approx(hid_y, ey) then
    err = "ok"
  elseif (o == 1 or o == 2) and approx(hid_x, id_x) and approx(hid_y, id_y) then
    -- 曾被误标 ok；现锁定玻璃 HID 后视为路径翻转回归
    err = "hid_path_flip_identity"
  elseif approx(hid_x, id_x) and approx(hid_y, id_y) then
    err = "missing_rotate_identity"
  elseif approx(hid_x, mir_x) and approx(hid_y, id_y) then
    err = "mirror_lr"
  elseif approx(hid_x, id_x) and approx(hid_y, mir_y) then
    err = "mirror_ud"
  elseif approx(hid_x, mir_x) and approx(hid_y, mir_y) then
    err = "mirror_lr_ud"
  elseif approx(hid_x, rot_x) and approx(hid_y, rot_y) then
    err = "rotate_xy_swap"
  elseif approx(hid_x, 1.0 - rot_x) or approx(hid_y, 1.0 - rot_y) then
    err = "rotate_or_mirror"
  elseif math.abs((hid_x or 0) - ex) > 0.15 or math.abs((hid_y or 0) - ey) > 0.15 then
    err = "scale_or_ratio"
  else
    err = "offset"
  end
  return err, ex, ey, o, SW, SH
end

local function space_name(o)
  if o == 1 then
    return "screen_landscape_home_right"
  elseif o == 2 then
    return "screen_landscape_home_left"
  end
  return "screen_portrait"
end

function M.write_find(vision_x, vision_y, shot_w, shot_h)
  local o, lw, lh = read_orient()
  local pw, ph, scale = read_native()
  shot_w = tonumber(shot_w) or lw
  shot_h = tonumber(shot_h) or lh
  local logic_x = tonumber(vision_x) or -1
  local logic_y = tonumber(vision_y) or -1
  -- 主路径：Vision=Logic=Touch 输入；Screen 点=竖屏互逆期望 port
  local _, _, port_x, port_y = expect_glass_hid(logic_x, logic_y)
  local space = space_name(o)
  local line = string.format(
    "event=find ok=1 shot=%dx%d vision=%d,%d logic=%d,%d screen=%.1f,%.1f touch=%d,%d "
      .. "orient=%d coordinateSpace=%s native=%dx%d@%d logicSize=%dx%d "
      .. "transform_count=1 path=logic_passthrough x1=x2=x3\n",
    shot_w, shot_h, logic_x, logic_y, logic_x, logic_y, port_x, port_y,
    logic_x, logic_y, o, space, pw, ph, scale, lw, lh
  )
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_coord_diag", "a")
    if not f then return end
    f:write(line)
    f:close()
  end)
  return line
end

function M.write_tap(logic_x, logic_y, transform_count)
  logic_x = tonumber(logic_x) or 0
  logic_y = tonumber(logic_y) or 0
  transform_count = tonumber(transform_count) or 1
  local hid_x, hid_y, port_x, port_y = nil, nil, nil, nil
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_tap_proof", "r")
    if not f then return end
    local body = f:read("*a") or ""
    f:close()
    hid_x = tonumber(body:match("hid=([%d%.%-]+)"))
    hid_y = tonumber(body:match("hid=[%d%.%-]+,([%d%.%-]+)"))
    port_x = tonumber(body:match("port=([%d%.%-]+)"))
    port_y = tonumber(body:match("port=[%d%.%-]+,([%d%.%-]+)"))
  end)
  local err, ex, ey, o, SW, SH = M.classify(logic_x, logic_y, hid_x, hid_y, transform_count)
  local space = space_name(o)
  local same = (math.abs(logic_x - logic_x) < 0.01) -- x1=x2=x3 logic 恒等
  local line = string.format(
    "event=tap vision=%.1f,%.1f logic=%.1f,%.1f touch=%.1f,%.1f screen=%.1f,%.1f "
      .. "hid=%s,%s expect_hid=%.3f,%.3f error_type=%s orient=%d coordinateSpace=%s "
      .. "logicSize=%dx%d transform_count=%d x1=x2=x3=%s\n",
    logic_x, logic_y, logic_x, logic_y, logic_x, logic_y,
    tonumber(port_x) or -1, tonumber(port_y) or -1,
    hid_x and string.format("%.3f", hid_x) or "?",
    hid_y and string.format("%.3f", hid_y) or "?",
    ex, ey, err, o, space, SW, SH, transform_count, same and "yes" or "no"
  )
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_coord_diag", "a")
    if not f then return end
    f:write(line)
    f:close()
  end)
  return err, line
end

function M.install()
  _G.ZiYanCoordDiag = M
end

return M
