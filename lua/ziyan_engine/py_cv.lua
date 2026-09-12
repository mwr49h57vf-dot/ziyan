--[[
  OCR / 网络 / 文件 / 找图桥
  ------------------------------------------------------------
  找色：cv.lua → SpringBoard ZiYanScreenBridge（不经本模块）
  OCR：ensure_shot(dumpScreen) → $ZIYAN_ROOT/bin/ziyan_ocr
       rootless=/var/jb/usr/lib/ziyan  rootful=/usr/lib/ziyan
  点触：全局 tap（touch.lua → AppTouch）
  网络：curl（NetTime / NetIp）
]]

local M = {}

local ZIYAN_VAR = _G.ZIYAN_VAR
if type(ZIYAN_VAR) ~= "string" or ZIYAN_VAR == "" then
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    ZIYAN_VAR = "/var/jb/usr/lib/ziyan/var"
  else
    ZIYAN_VAR = "/usr/lib/ziyan/var"
  end
end
-- rootless/rootful 统一：VAR 的上一级即 runtime root
local ZIYAN_ROOT = (type(_G.ZIYAN_ROOT) == "string" and _G.ZIYAN_ROOT ~= "" and _G.ZIYAN_ROOT)
  or ZIYAN_VAR:gsub("/var$", "")
-- 用户默认可读写（截图/OCR临时/导出）；IPC 仍走 ZIYAN_VAR
local ZIYAN_ZYCV = (type(_G.ZIYAN_ZYCV) == "string" and _G.ZIYAN_ZYCV ~= "" and _G.ZIYAN_ZYCV)
  or "/private/var/mobile/Media/ZiYan/ZYCV"
do
  local kf = io.open(ZIYAN_ZYCV .. "/.keep", "a")
  if kf then kf:close() end
end
local CV_BIN = ZIYAN_ROOT .. "/bin/ziyan_cv/run" -- 已拆除，仅兼容旧调用
local OCR_BIN = ZIYAN_ROOT .. "/bin/ziyan_ocr"
local SHOT = ZIYAN_ZYCV .. "/.ziyan_cv_shot.png"
local REQ_FILE = ZIYAN_VAR .. "/.ziyan_cv_req.json"
local REP_FILE = ZIYAN_VAR .. "/.ziyan_cv_rep.json"
local TRIG_FILE = ZIYAN_VAR .. "/.ziyan_cv_trig"
local DAEMON_PID = ZIYAN_VAR .. "/.ziyan_cv_daemon.pid"
-- 引擎 Tesseract 3 + 包内 tessdata（chi_sim 约 40MB，2GB 内存机易 OOM，默认不用）
local TESSDATA = ZIYAN_ROOT .. "/tessdata"
local OCR_CHI_FLAG = ZIYAN_VAR .. "/.ziyan_ocr_chi" -- 存在才启用 localOcr chi_sim


local function defined(n) return type(_G[n]) == "function" end

local function json_encode(t)
  if type(jsonEncode) == "function" then
    return jsonEncode(t)
  end
  local ok, json = pcall(require, "json")
  if ok and json and json.encode then
    return json.encode(t)
  end
  error("jsonEncode unavailable")
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

--- rootless 无 /bin/sh：os.execute(cp/rm) 常失败，用纯 Lua 读写
local function file_copy(src, dst)
  if type(src) ~= "string" or type(dst) ~= "string" or src == "" or dst == "" then
    return false
  end
  local rf = io.open(src, "rb")
  if not rf then return false end
  local data = rf:read("*a") or ""
  rf:close()
  if #data < 1 then return false end
  local wf = io.open(dst, "wb")
  if not wf then return false end
  wf:write(data)
  wf:close()
  return true
end

local function remove_if_exists(path)
  if type(path) == "string" and path ~= "" then
    pcall(os.remove, path)
  end
end

local function daemon_alive()
  local f = io.open(DAEMON_PID, "r")
  if not f then return false end
  local s = f:read("*l") or ""
  f:close()
  local pid = tonumber(s)
  if not pid or pid < 2 then return false end
  -- kill -0
  local st = os.execute("kill -0 " .. tostring(pid) .. " 2>/dev/null")
  if st == true or st == 0 then return true end
  return false
end

local function ensure_daemon()
  if daemon_alive() then return true end
  -- 后台常驻，首次找色后后续毫秒级
  os.execute(string.format(
    "nohup '%s' daemon >/dev/null 2>&1 &", CV_BIN
  ))
  for _ = 1, 50 do
    if daemon_alive() then return true end
    if type(mSleep) == "function" then mSleep(20) else os.execute("sleep 0.02") end
  end
  return daemon_alive()
end

local function read_rep()
  local r = io.open(REP_FILE, "r")
  if not r then
    return nil, "no_reply"
  end
  local body = r:read("*a") or ""
  r:close()
  if body == "" then
    return nil, "empty_reply"
  end
  local ok, obj = pcall(json_decode, body)
  if not ok or type(obj) ~= "table" then
    return nil, "bad_json"
  end
  return obj
end

--- 调 Python：优先常驻 daemon，失败再一次性 run
function M.call(req)
  if type(req) ~= "table" then
    return { ok = false, error = "bad_req" }
  end
  if type(_G.__ZIYAN_wait_while_paused) == "function" then
    _G.__ZIYAN_wait_while_paused()
  end

  local payload = json_encode(req)
  local f = io.open(REQ_FILE, "w")
  if not f then
    return { ok = false, error = "cannot_write_req" }
  end
  f:write(payload)
  f:write("\n")
  f:close()

  -- 清旧回复，避免读到上一次结果
  pcall(os.remove, REP_FILE)

  local BUSY = ZIYAN_VAR .. "/.ziyan_cv_busy"
  local used_daemon = ensure_daemon()
  if used_daemon then
    local tf = io.open(TRIG_FILE, "w")
    if tf then
      tf:write("1\n")
      tf:close()
    end
    -- 等 daemon 写出 rep（找色通常 <100ms，首包可到 1s）
    for _ = 1, 200 do
      if type(_G.__ZIYAN_wait_while_paused) == "function" then
        _G.__ZIYAN_wait_while_paused()
      end
      local obj = read_rep()
      if obj then
        pcall(os.remove, BUSY)
        return obj
      end
      if type(mSleep) == "function" then mSleep(10) else os.execute("sleep 0.01") end
    end
  end

  -- 回退：一次性进程
  local bf = io.open(BUSY, "w")
  if bf then
    bf:write("1\n")
    bf:close()
  end
  local cmd = string.format(
    "'%s' -f '%s' > '%s' 2>/dev/null",
    CV_BIN, REQ_FILE, REP_FILE
  )
  os.execute(cmd)
  pcall(os.remove, BUSY)

  if type(_G.__ZIYAN_wait_while_paused) == "function" then
    _G.__ZIYAN_wait_while_paused()
  end

  local obj, err = read_rep()
  if obj then return obj end
  return { ok = false, error = err or "no_reply" }
end

--- 截屏到 SHOT：优先 ScreenBridge dumpScreen（OCR 必需）
local function file_size(p)
  local f = io.open(p, "rb")
  if not f then return 0 end
  local sz = f:seek("end") or 0
  f:close()
  return tonumber(sz) or 0
end

local function ensure_shot()
  -- 截屏节流：1.5 秒内已有截图则复用，降低 SpringBoard 主线程截屏频率
  local now = os.time()
  if _G.__ZIYAN_LAST_SHOT_T and (now - _G.__ZIYAN_LAST_SHOT_T) < 1.5 then
    if file_size(SHOT) > 100 then
      return SHOT
    end
  end

  -- 1) ScreenBridge 逻辑截屏 → .ziyan_cv_shot.png
  local native = _G.ZiYanCV_Native
  local path = nil
  if type(native) == "table" and type(native.dump_screen) == "function" then
    path = native.dump_screen(SHOT)
  end
  if (not path or file_size(path) < 100) and type(dumpScreen) == "function" then
    path = dumpScreen(SHOT)
  end
  if path and file_size(path) > 100 then
    _G.__ZIYAN_LAST_SHOT_T = now
    return path
  end
  -- 2) 已有 Media 取色图
  local media = "/private/var/mobile/Media/ZiYan/ZYCV/ts_shot.png"
  local media_legacy = "/private/var/mobile/Media/ZiYan/ts_shot.png"
  if file_size(media) > 100 then
    if file_copy(media, SHOT) and file_size(SHOT) > 100 then return SHOT end
    return media
  end
  if file_size(media_legacy) > 100 then
    if file_copy(media_legacy, SHOT) and file_size(SHOT) > 100 then return SHOT end
    return media_legacy
  end
  -- 3) 引擎原生 snapshot
  if type(snapshotScreen) == "function" then
    pcall(snapshotScreen, SHOT, 100)
    if file_size(SHOT) > 100 then return SHOT end
  end
  if type(_snapshot) == "function" then
    pcall(_snapshot, SHOT, 0, 0, -1, -1, 100)
    if file_size(SHOT) > 100 then return SHOT end
  end
  if type(keepScreen) == "function" then
    pcall(keepScreen, true)
  end
  return SHOT
end

--- 横屏逻辑区域：越界自动夹到屏幕内；-1 = 全屏
--- 尺寸优先 .ziyan_orient（与 ScreenBridge 像素缓冲一致，如 2208x1242）
local function logic_region(x, y, x1, y1)
  local lw, lh = 1136, 640
  local of = io.open((type(ZIYAN_VAR) == "string" and ZIYAN_VAR or "") .. "/.ziyan_orient", "r")
  if not of and type(_G.ZIYAN_VAR) == "string" then
    of = io.open(_G.ZIYAN_VAR .. "/.ziyan_orient", "r")
  end
  if of then
    of:read("*l")
    local a = tonumber(of:read("*l") or "") or 0
    local b = tonumber(of:read("*l") or "") or 0
    of:close()
    if a > 1 and b > 1 then
      lw, lh = a, b
    end
  elseif ZiYanOrient and type(ZiYanOrient.logical_size) == "function" then
    local a, b = ZiYanOrient.logical_size()
    if tonumber(a) and tonumber(b) and a > 0 and b > 0 then
      lw, lh = a, b
    end
  elseif type(getScreenSize) == "function" then
    local ok, a, b = pcall(getScreenSize)
    if ok and tonumber(a) and tonumber(b) and a > 0 and b > 0 then
      -- getScreenSize 偶发返回点距；若远小于 orient 典型值则放大到 3x
      if a < 1000 and b < 1000 and a >= 300 then
        lw, lh = math.floor(a * 3), math.floor(b * 3)
      else
        lw, lh = a, b
      end
    end
  end
  x = math.floor(tonumber(x) or 0)
  y = math.floor(tonumber(y) or 0)
  x1 = tonumber(x1)
  y1 = tonumber(y1)
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end
  if not x1 or x1 < 0 then x1 = lw - 1 end
  if not y1 or y1 < 0 then y1 = lh - 1 end
  if x1 >= lw then x1 = lw - 1 end
  if y1 >= lh then y1 = lh - 1 end
  if x1 < x then x, x1 = x1, x end
  if y1 < y then y, y1 = y1, y end
  x = math.min(math.max(0, x), lw - 1)
  y = math.min(math.max(0, y), lh - 1)
  return x, y, x1, y1
end

local function file_exists(p)
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

local function parse_ocr_text(text, via, lang, x, y, x1, y1)
  text = tostring(text or ""):gsub("[\r\n]+$", "")
  local numbers = {}
  for n in text:gmatch("[-+]?%d+%.?%d*") do
    local v = tonumber(n)
    if v ~= nil then numbers[#numbers + 1] = v end
  end
  return {
    ok = true,
    text = text,
    numbers = numbers,
    number = numbers[1],
    via = via,
    lang = lang,
    region = { x, y, x1, y1 },
  }
end

--- 引擎 local OCR：默认 eng（稳）；chi_sim 仅当存在 .ziyan_ocr_chi（防 2GB 机 OOM）
local function local_ocr_text(x, y, x1, y1)
  -- 8-161-95：禁 keepScreen(true) 锁帧（旧路径无配对 false → 帧/堆滞留）
  local fn = localOcrText
  if type(fn) ~= "function" and type(_localOcrText) == "function" then
    fn = function(tess, lg, a, b, c, d, wl)
      return _localOcrText(tess, lg, a, b, c, d, wl or "")
    end
  end
  if type(fn) ~= "function" then
    return nil
  end

  -- 仅使用子砚自带 tessdata，不回退第三方 App 路径
  if not file_exists(TESSDATA .. "/eng.traineddata") then
    return nil
  end
  local tess = TESSDATA

  -- 可选：高内存机启用中文；默认也尝试 chi_sim（有 tessdata 且引擎提供 localOcrText）
  local preferChi = file_exists(OCR_CHI_FLAG) or file_exists(TESSDATA .. "/chi_sim.traineddata")
  if preferChi and file_exists(TESSDATA .. "/chi_sim.traineddata") then
    local ok, text = pcall(fn, TESSDATA, "chi_sim", x, y, x1, y1, "")
    if ok and text and tostring(text) ~= "" then
      return parse_ocr_text(text, "localOcr", "chi_sim", x, y, x1, y1)
    end
  end

  -- eng：数字/英文稳定，不占大内存
  local ok, text = pcall(fn, tess, "eng", x, y, x1, y1, "")
  if ok and text and tostring(text) ~= "" then
    return parse_ocr_text(text, "localOcr", "eng", x, y, x1, y1)
  end
  return nil
end

--- 可选云端 OCR：配置文件 .ziyan_cloud_ocr = user\\npass\\nsoftid
local function cloud_ocr_text(x, y, x1, y1)
  if type(cloudOcrText) ~= "function" then
    return nil
  end
  local cfg = ZIYAN_VAR .. "/.ziyan_cloud_ocr"
  local f = io.open(cfg, "r")
  if not f then return nil end
  local user = (f:read("*l") or ""):gsub("%s+$", "")
  local pass = (f:read("*l") or ""):gsub("%s+$", "")
  local soft = tonumber((f:read("*l") or "0"):match("%d+") or "0") or 0
  f:close()
  if user == "" then return nil end
  -- 8-161-95：禁 keep 锁帧（无配对释放）
  local ok, text = pcall(cloudOcrText, user, pass, soft, x, y, x1, y1)
  if ok and text and tostring(text) ~= "" and not tostring(text):find("失败") then
    return parse_ocr_text(text, "cloudOcr", "ch", x, y, x1, y1)
  end
  return nil
end

local function ocr_req(op, extra)
  extra = extra or {}
  local x, y, x1, y1 = logic_region(
    extra.x, extra.y, extra.x1, extra.y1
  )

  local is_rootless = type(ZIYAN_ROOT) == "string" and ZIYAN_ROOT:find("/var/jb", 1, true) ~= nil

  local function has_cjk(s)
    if type(s) ~= "string" or s == "" then return false end
    if utf8 and type(utf8.codes) == "function" then
      for _, cp in utf8.codes(s) do
        if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) then
          return true
        end
      end
      return false
    end
    return s:find("[\228-\233][\128-\191][\128-\191]") ~= nil
  end

  local function cleanup_ocr_temps()
    -- 8-161-95：对照触动 tmp 不堆积 — 成功/失败都清临时图 + 全屏 SHOT
    local names = {
      ZIYAN_ZYCV .. "/.ziyan_ocr_tmp.png",
      ZIYAN_ZYCV .. "/.ziyan_dump.png",
      ZIYAN_ZYCV .. "/.ziyan_usb_color_dump.png",
      ZIYAN_ZYCV .. "/.ziyan_cv_shot.png",
      ZIYAN_ZYCV .. "/ts_shot.png",
      ZIYAN_VAR .. "/.ziyan_ocr_tmp.png",
      ZIYAN_VAR .. "/.ziyan_dump.png",
      ZIYAN_VAR .. "/.ziyan_usb_color_dump.png",
      ZIYAN_VAR .. "/.ziyan_ocr_err.txt",
    }
    for _, p in ipairs(names) do
      remove_if_exists(p)
    end
    -- SHOT 常量路径
    if type(SHOT) == "string" then remove_if_exists(SHOT) end
    local t = os.time() % 100000
    for i = 0, 50 do
      remove_if_exists(string.format("%s/.ziyan_ocr_tmp_%d.png", ZIYAN_ZYCV, (t - i) % 100000))
      remove_if_exists(string.format("%s/.ziyan_ocr_tmp_%d.png", ZIYAN_VAR, (t - i) % 100000))
    end
    os.execute(string.format(
      "rm -f '%s'/.ziyan_ocr_tmp*.png '%s'/.ziyan_dump*.png '%s'/.ziyan_cv_shot.png '%s'/ts_shot.png '%s'/.ziyan_ocr_tmp*.png '%s'/.ziyan_dump*.png 2>/dev/null",
      ZIYAN_ZYCV, ZIYAN_ZYCV, ZIYAN_ZYCV, ZIYAN_ZYCV, ZIYAN_VAR, ZIYAN_VAR))
  end

  local function try_sb_ocr()
    local native = _G.ZiYanCV_Native
    if type(native) ~= "table" or type(native.ocr_region) ~= "function" then
      return nil
    end
    local okc, obj = pcall(native.ocr_region, x, y, x1, y1)
    if not okc or type(obj) ~= "table" then
      return nil
    end
    if obj.text == nil then obj.text = "" end
    obj.ok = obj.ok ~= false
    obj.via = obj.via or "sb_ocr"
    obj.region = { x, y, x1, y1 }
    return obj
  end

  -- 203：硬 gate + ≥350ms；缓存键含 daemon front_generation/seq
  local gate_ok = true
  local front_bid = ""
  local front_gen, frame_seq = 0, 0
  pcall(function()
    local cv = package.loaded["ziyan_engine.cv"]
    if type(cv) == "table" and type(cv.vision_gate) == "function" then
      local ok, snap = cv.vision_gate("ocr")
      gate_ok = ok and true or false
      if type(snap) == "table" then
        front_bid = tostring(snap.front_bid or "")
        front_gen = tonumber(snap.front_generation) or 0
        frame_seq = tonumber(snap.seq) or 0
      end
    end
  end)
  -- 触动：OCR 扫当前画面。gate 失败不再直接 VISION_STALE。
  local OCR_MIN_MS = 350
  local OCR_CACHE_MS = 5000
  local ocr_cache = _G.__ZIYAN_OCR_CACHE
  if not ocr_cache then
    ocr_cache = { t = 0, region = {}, result = nil, front = "", gen = -1, seq = -1 }
    _G.__ZIYAN_OCR_CACHE = ocr_cache
  end
  local now_ms = os.time() * 1000 + math.floor((os.clock() % 1) * 1000)
  local last_ocr_t = tonumber(_G.__ZIYAN_OCR_LAST_MS) or 0
  if last_ocr_t > 0 and (now_ms - last_ocr_t) < OCR_MIN_MS then
    local wait_ms = OCR_MIN_MS - (now_ms - last_ocr_t)
    if wait_ms > 0 and wait_ms < 400 then
      if type(mSleep) == "function" then
        pcall(mSleep, wait_ms)
      elseif type(ziyan_embed_msleep) == "function" then
        pcall(ziyan_embed_msleep, wait_ms)
      end
      now_ms = os.time() * 1000 + math.floor((os.clock() % 1) * 1000)
    end
  end
  local region_match = (#ocr_cache.region == 4 and
                        ocr_cache.region[1] == x and ocr_cache.region[2] == y and
                        ocr_cache.region[3] == x1 and ocr_cache.region[4] == y1 and
                        tostring(ocr_cache.front or "") == front_bid and
                        tonumber(ocr_cache.gen or -2) == front_gen and
                        tonumber(ocr_cache.seq or -2) == frame_seq)
  if region_match and ocr_cache.result and (now_ms - ocr_cache.t) < OCR_CACHE_MS then
    local cached = ocr_cache.result
    cached.cached = true
    cached.cache_age_ms = now_ms - ocr_cache.t
    return cached
  end
  _G.__ZIYAN_OCR_LAST_MS = now_ms

  local function try_cli_ocr(img_path)
    local outf = ZIYAN_VAR .. "/.ziyan_ocr_out.json"
    local errf = ZIYAN_VAR .. "/.ziyan_ocr_err.txt"
    pcall(os.remove, outf)
    pcall(os.remove, errf)
    if not file_exists(OCR_BIN) then
      return {
        ok = false, text = "", error = "missing_ziyan_ocr", via = "ziyan_ocr",
        bin = OCR_BIN, region = { x, y, x1, y1 },
      }
    end
    local path = img_path
    local use_region = true
    if type(path) ~= "string" or path == "" or file_size(path) < 100 then
      path = ensure_shot()
      if file_size(path) < 100 then
        return {
          ok = false, text = "", error = "screenshot_failed", via = "ziyan_ocr",
          region = { x, y, x1, y1 },
        }
      end
    else
      -- 临时 ROI 图已是裁切结果：整图识别
      use_region = false
    end
    local cmd
    if use_region then
      cmd = string.format(
        "'%s' '%s' %d %d %d %d --json > '%s' 2>'%s'",
        OCR_BIN, path, x, y, x1, y1, outf, errf)
    else
      cmd = string.format(
        "'%s' '%s' --json > '%s' 2>'%s'",
        OCR_BIN, path, outf, errf)
    end
    os.execute(cmd)
    local py = { ok = false, text = "" }
    local rf = io.open(outf, "r")
    if rf then
      local body = rf:read("*a") or ""
      rf:close()
      local obj = nil
      if type(body) == "string" and body:find("%S") then
        obj = json_decode(body)
      end
      if type(obj) == "table" then
        py = obj
        if py.text == nil then py.text = "" end
        py.ok = py.ok ~= false
        py.via = py.via or "ziyan_ocr"
        py.bin = OCR_BIN
        py.shot = path
        py.region = { x, y, x1, y1 }
      end
    end
    return py
  end

  --- 失败时落盘临时图 → 二次识别 → 必删（固定名，避免残留）
  local function retry_via_temp_dump(reason)
    local tmp = ZIYAN_ZYCV .. "/.ziyan_ocr_tmp.png"
    remove_if_exists(tmp)
    local shot = ensure_shot()
    local saved = false
    if file_size(shot) > 100 then
      saved = file_copy(shot, tmp)
      if not saved then
        os.execute(string.format("cp '%s' '%s' 2>/dev/null", shot, tmp))
        saved = file_size(tmp) > 100
      end
    end
    if not saved then
      return {
        ok = false, text = "", error = tostring(reason or "no_temp"),
        via = "ocr_temp_fail", region = { x, y, x1, y1 },
      }
    end
    local second = nil
    -- 临时图二次识别：仅 CLI（SB Vision 已禁用，防 jetsam）
    if not second or tostring(second.text or "") == "" then
      second = try_cli_ocr(tmp)
    end
    remove_if_exists(tmp)
    cleanup_ocr_temps()
    if type(second) ~= "table" then
      second = { ok = false, text = "", error = "retry_nil" }
    end
    second.via = tostring(second.via or "") .. "+temp_retry"
    second.retry_reason = tostring(reason or "")
    second.region = { x, y, x1, y1 }
    return second
  end

  cleanup_ocr_temps()

  -- 203：默认走 daemon ocrRoi（当前帧 ROI），禁全屏 dump / 禁 SB Vision
  local function try_daemon_ocr_roi()
    local cv = package.loaded["ziyan_engine.cv"]
    local n = tostring(os.time()) .. tostring(math.floor((os.clock() % 1) * 1e6))
    local payload = table.concat({
      "ocrRoi",
      tostring(x or 0),
      tostring(y or 0),
      tostring(x1 or -1),
      tostring(y1 or -1),
      n,
    }, "\n") .. "\n"
    local var = ZIYAN_VAR or (_G.ZIYAN_VAR or "/usr/lib/ziyan/var")
    local req = var .. "/.ziyan_color_req"
    local rep = var .. "/.ziyan_color_rep"
    pcall(os.remove, rep)
    local wf = io.open(req, "w")
    if not wf then
      return { ok = false, text = "", error = "color_req_open", via = "daemon_ocrRoi" }
    end
    wf:write(payload)
    wf:close()
    local body = nil
    local t0 = os.clock()
    while (os.clock() - t0) < 6.0 do
      local rf = io.open(rep, "r")
      if rf then
        local all = rf:read("*a") or ""
        rf:close()
        if all:find(n, 1, true) then
          body = all
          break
        end
      end
      if type(mSleep) == "function" then
        pcall(mSleep, 40)
      end
    end
    if type(body) ~= "string" then
      return { ok = false, text = "", error = "ocr_timeout", via = "daemon_ocrRoi" }
    end
    local json_part = body:match("\nok\n(.+)$") or body:match("\n(.+)$")
    local obj = json_part and json_decode(json_part) or nil
    if type(obj) ~= "table" then
      return { ok = false, text = "", error = "ocr_bad_json", via = "daemon_ocrRoi" }
    end
    obj.via = obj.via or "daemon_ocrRoi"
    obj.region = { x, y, x1, y1 }
    return obj
  end

  local py = try_daemon_ocr_roi()
  if (not py or tostring(py.text or "") == "") and type(OCR_BIN) == "string" and file_exists(OCR_BIN) then
    -- 冷回退：仅当 daemon ROI 失败；仍禁止默认 SB Vision
    local cli = try_cli_ocr(nil)
    if cli and tostring(cli.text or "") ~= "" then
      py = cli
      py.via = tostring(py.via or "ziyan_ocr") .. "+cli_fallback"
    end
  end
  cleanup_ocr_temps()
  if type(py) ~= "table" then
    py = { ok = false, text = "", error = "ocr_nil", via = "daemon_ocrRoi" }
  end

  local py_text = (py and py.ok and tostring(py.text or "")) or ""
  cleanup_ocr_temps()

  -- 缓存本次 OCR 结果（5 秒）；键含 front/gen/seq
  do
    local c = _G.__ZIYAN_OCR_CACHE
    if c then
      c.front = front_bid
      c.gen = front_gen
      c.seq = frame_seq
      c.t = os.time() * 1000 + math.floor((os.clock() % 1) * 1000)
      c.region = { x, y, x1, y1 }
      c.result = py
    end
  end

  -- 持久化最近一次 OCR JSON
  do
    local outf = ZIYAN_VAR .. "/.ziyan_ocr_out.json"
    local f = io.open(outf, "w")
    if f and type(json_encode) == "function" then
      local okj, body = pcall(json_encode, py)
      if okj and body then f:write(body) end
      f:close()
    elseif f then
      f:write(string.format(
        "{\"ok\":%s,\"text\":%q,\"via\":%q}",
        py.ok and "true" or "false", tostring(py.text or ""), tostring(py.via or "")))
      f:close()
    end
  end

  -- 8-161-98：空识别勿每圈跑 cloud/local（Tesseract/网络可把 while-true 卡死在 getText）
  -- 仅当 SB 已有非空但无汉字、或显式 __ZIYAN_OCR_FALLBACK=true 才兜底
  if op == "getText" or op == "strFind" or op == "findNumber" or op == "findStr" then
    local want_fb = (_G.__ZIYAN_OCR_FALLBACK == true)
        or (py_text ~= "" and not has_cjk(py_text))
    if want_fb and not has_cjk(py_text) then
      local cloud = cloud_ocr_text(x, y, x1, y1)
      if cloud and cloud.text ~= "" then
        if op == "findStr" and extra.str then
          if string.find(cloud.text, tostring(extra.str), 1, true) then
            cloud.x = math.floor((x + x1) / 2)
            cloud.y = math.floor((y + y1) / 2)
            cloud.match = cloud.text
            cloud.needle = tostring(extra.str)
            return cloud
          end
        else
          return cloud
        end
      end
      local loc = local_ocr_text(x, y, x1, y1)
      if loc and loc.text ~= "" then
        if py and py.ok and py_text ~= "" then
          if (not py.numbers or not py.numbers[1]) and loc.number then
            py.numbers = loc.numbers
            py.number = loc.number
            py.via = tostring(py.via or "") .. "+localOcr"
          end
          return py
        end
        if op == "findStr" and extra.str then
          if string.find(loc.text, tostring(extra.str), 1, true) then
            loc.x = math.floor((x + x1) / 2)
            loc.y = math.floor((y + y1) / 2)
            loc.match = loc.text
            loc.needle = tostring(extra.str)
            return loc
          end
        else
          return loc
        end
      end
    end
  end
  -- 空字：ok=false，供 getText → nil（Lua 中 "" 为真，会卡死 if result then）
  if py and type(py) == "table" then
    local t = tostring(py.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    py.text = t
    if t == "" then
      py.ok = false
      if not py.error or py.error == "" then
        py.error = "empty_text"
      end
    end
  end

  -- 规范化 UTF-8 文本
  if py and type(py.text) == "string" then
    py.text = py.text:gsub("\r\n", "\n"):gsub("\r", "\n")
  end
  return py
end

function M.find_color(opts)
  opts = opts or {}
  local color = opts.color or opts.first_color
  local colors = opts.colors or opts.offset or opts.offset_colors
  local fuzzy = opts.fuzzy or 90
  local x1, y1, x2, y2 = 0, 0, -1, -1
  if opts.region and #opts.region >= 4 then
    x1, y1, x2, y2 = opts.region[1], opts.region[2], opts.region[3], opts.region[4]
  else
    x1, y1 = opts.x1 or 0, opts.y1 or 0
    x2, y2 = opts.x2 or -1, opts.y2 or -1
  end
  -- 抓色器架构：主色 + "dx|dy|0x.." 偏点串
  if type(colors) == "string" and color ~= nil then
    local x, y = M.findMultiColorInRegionFuzzy(color, colors, fuzzy, x1, y1, x2, y2)
    if x and x >= 0 then return { ok = true, x = x, y = y } end
    return { ok = false, x = -1, y = -1 }
  end
  local flat = colors or color
  if type(flat) ~= "table" then
    flat = { tonumber(flat) or 0 }
  end
  local x, y = M.findMultiColorInRegionFuzzy(flat, fuzzy, x1, y1, x2, y2)
  if x and x >= 0 then return { ok = true, x = x, y = y } end
  return { ok = false, x = -1, y = -1 }
end

--- 与抓色器 / cv.lua 一致：返回 x, y（勿再包成 table）
--- TS: (0x主色, "dx|dy|0x..,...", degree, x1,y1,x2,y2)
--- TE: (flatTable, degree, x1,y1,x2,y2)
function M.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
  if type(_G.ZiYanCV_Native) == "table"
      and type(_G.ZiYanCV_Native.findMultiColorInRegionFuzzy) == "function" then
    local x, y = _G.ZiYanCV_Native.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
    return tonumber(x) or -1, tonumber(y) or -1
  end
  if type(_G.findMultiColorInRegionFuzzy) == "function" then
    -- 避免递归：仅当全局已是 cv 安装体且非本模块包装时调用
    local x, y = _G.findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
    return tonumber(x) or -1, tonumber(y) or -1
  end
  return -1, -1
end

function M.find_multi_color_in_region_fuzzy(...)
  return M.findMultiColorInRegionFuzzy(...)
end

--- 别名：与抓色器 findMultiColor 同参
function M.findMultiColor(...)
  return M.findMultiColorInRegionFuzzy(...)
end

function M.find_image(opts)
  opts = opts or {}
  local path = opts.template or opts.path or opts[1]
  if type(path) ~= "string" or path == "" then
    return { ok = false, x = -1, y = -1, error = "no_template" }
  end
  -- 相对路径：优先 Media/ZiYan，再 var
  if path:sub(1, 1) ~= "/" then
    local candidates = {
      "/private/var/mobile/Media/ZiYan/" .. path,
      ZIYAN_VAR .. "/" .. path,
      path,
    }
    path = nil
    for _, p in ipairs(candidates) do
      local f = io.open(p, "rb")
      if f then f:close(); path = p; break end
    end
    if not path then
      return { ok = false, x = -1, y = -1, error = "template_missing" }
    end
  end
  local native = _G.ZiYanCV_Native
  if type(native) == "table" and type(native.find_image) == "function" then
    local x, y = native.find_image(
      path, opts.fuzzy or 80,
      opts.x1 or 0, opts.y1 or 0, opts.x2 or -1, opts.y2 or -1
    )
    if x and x >= 0 then
      return { ok = true, x = x, y = y, path = path }
    end
    return { ok = false, x = -1, y = -1, path = path }
  end
  return { ok = false, x = -1, y = -1, error = "no_native_find_image" }
end

function M.tap(x, y, hold_ms, backend)
  if type(tap) == "function" then
    local ok = tap(x, y, hold_ms or 50)
    return { ok = ok and true or false, backend = backend }
  end
  return { ok = false, error = "no_tap" }
end

function M.swipe(x1, y1, x2, y2, duration_ms, backend)
  if type(swipe) == "function" then
    local ok = swipe(x1, y1, x2, y2, duration_ms or 400)
    return { ok = ok and true or false, backend = backend }
  end
  -- 兜底：moveTo
  if type(moveTo) == "function" then
    local dist = math.max(math.abs((x2 or 0) - (x1 or 0)), math.abs((y2 or 0) - (y1 or 0)), 1)
    local step = math.max(4, math.floor(dist / 20))
    local n = math.max(1, math.floor(dist / step))
    local ms = math.max(1, math.floor((duration_ms or 400) / n))
    pcall(moveTo, x1, y1, x2, y2, step, ms)
    return { ok = true, backend = backend or "moveTo" }
  end
  return { ok = false, error = "no_swipe" }
end

function M.ocr_backends()
  local list = {}
  if file_exists(OCR_BIN) then
    list[#list + 1] = "ziyan_ocr"
  end
  if type(localOcrText) == "function" or type(_localOcrText) == "function" then
    list[#list + 1] = "localOcr"
  end
  if type(cloudOcrText) == "function" and file_exists(ZIYAN_VAR .. "/.ziyan_cloud_ocr") then
    list[#list + 1] = "cloudOcr"
  end
  if file_exists(TESSDATA .. "/chi_sim.traineddata") then
    list[#list + 1] = "tessdata_chi_sim"
  end
  if file_exists(TESSDATA .. "/eng.traineddata") then
    list[#list + 1] = "tessdata_eng"
  end
  return { ok = true, backends = list }
end

function M.capture_region(x, y, x1, y1, out_path)
  x, y, x1, y1 = logic_region(x, y, x1, y1)
  out_path = out_path or (ZIYAN_ZYCV .. "/.ziyan_region.png")
  local shot = ensure_shot()
  if file_size(shot) < 100 then
    return { ok = false, error = "no_shot" }
  end
  -- 无 sips 时用 Python 裁 PNG；失败则整图拷贝（region 仍返回）
  local w = math.max(1, x1 - x + 1)
  local h = math.max(1, y1 - y + 1)
  local py = string.format([[/usr/lib/ziyan/bin/python3 -c "
import struct,zlib,sys
src,dst=%q,%q
x,y,cw,ch=%d,%d,%d,%d
def paeth(a,b,c):
  p=a+b-c; pa,pb,pc=abs(p-a),abs(p-b),abs(p-c)
  return a if pa<=pb and pa<=pc else (b if pb<=pc else c)
raw=open(src,'rb').read()
assert raw[:8]==b'\x89PNG\r\n\x1a\n'
W,H=struct.unpack('>II', raw[16:24])
ctype=raw[25]
i=8; idat=b''
while i<len(raw):
  ln=struct.unpack('>I', raw[i:i+4])[0]; tag=raw[i+4:i+8]; chunk=raw[i+8:i+8+ln]; i+=12+ln
  if tag==b'IDAT': idat+=chunk
  if tag==b'IEND': break
data=zlib.decompress(idat)
bpp=4 if ctype==6 else (3 if ctype==2 else 1)
stride=1+W*bpp
rows=[]
prev=bytearray(W*bpp)
for r in range(H):
  o=r*stride; ft=data[o]; row=bytearray(data[o+1:o+stride])
  if ft==1:
    for j in range(bpp,len(row)): row[j]=(row[j]+row[j-bpp])&255
  elif ft==2:
    for j in range(len(row)): row[j]=(row[j]+prev[j])&255
  elif ft==3:
    for j in range(len(row)):
      left=row[j-bpp] if j>=bpp else 0
      row[j]=(row[j]+((left+prev[j])//2))&255
  elif ft==4:
    for j in range(len(row)):
      left=row[j-bpp] if j>=bpp else 0
      up=prev[j]; upl=prev[j-bpp] if j>=bpp else 0
      row[j]=(row[j]+paeth(left,up,upl))&255
  rows.append(row); prev=row
x=max(0,min(x,W-1)); y=max(0,min(y,H-1))
cw=max(1,min(cw,W-x)); ch=max(1,min(ch,H-y))
out=bytearray()
for yy in range(y,y+ch):
  out.append(0)
  out += rows[yy][x*bpp:(x+cw)*bpp]
  if bpp==3:
    # pad to RGBA for simplicity rewrite as RGB PNG
    pass
comp=zlib.compress(bytes(out),9)
def chunk(t,b):
  return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',cw,ch,8,ctype,0,0,0))+chunk(b'IDAT',comp)+chunk(b'IEND',b'')
open(dst,'wb').write(png)
" 2>/dev/null]], shot, out_path, x, y, w, h)
  local st = os.execute(py)
  if (st == true or st == 0) and file_size(out_path) > 100 then
    return { ok = true, path = out_path, region = { x, y, x1, y1 }, via = "png_crop" }
  end
  os.execute(string.format('cp -f "%s" "%s" 2>/dev/null', shot, out_path))
  if file_size(out_path) > 100 then
    return { ok = true, path = out_path, region = { x, y, x1, y1 }, via = "full_copy" }
  end
  return { ok = false, error = "crop_failed" }
end

function M.snapshot(path)
  path = path or SHOT
  local native = _G.ZiYanCV_Native
  if type(native) == "table" and type(native.dump_screen) == "function" then
    local p = native.dump_screen(path)
    if p and file_size(p) > 100 then
      return { ok = true, path = p, via = "dumpScreen" }
    end
  end
  if type(snapshotScreen) == "function" then
    pcall(snapshotScreen, path, 100)
    if file_size(path) > 100 then
      return { ok = true, path = path, via = "snapshotScreen" }
    end
  end
  return { ok = false, error = "no_snapshot" }
end

--- 打开任意 App（bid 必传）
function M.open_app(bid, method)
  bid = tostring(bid or "")
  if bid == "" then
    return { ok = false, error = "missing_bid" }
  end
  if type(appRun) == "function" then
    local ok = appRun(bid)
    return { ok = ok and true or false, method = method or "appRun" }
  end
  os.execute(string.format('uiopen "%s" >/dev/null 2>&1', bid))
  return { ok = true, method = "uiopen" }
end

--- 关闭任意 App（bid 必传）
function M.close_app(bid, method)
  bid = tostring(bid or "")
  if bid == "" then
    return { ok = false, error = "missing_bid" }
  end
  if type(appKill) == "function" then
    local ok = appKill(bid)
    return { ok = ok and true or false, method = method or "appKill" }
  end
  return { ok = false, error = "no_appKill" }
end

--- 区域 OCR：返回完整结果表
function M.str_find(x, y, x1, y1)
  return ocr_req("strFind", { x = x, y = y, x1 = x1, y1 = y1 })
end

--- 查找指定文字：返回详情表
function M.find_str(str, x, y, x1, y1)
  return ocr_req("findStr", { str = str, x = x, y = y, x1 = x1, y1 = y1 })
end

--- 识别区域内数字：返回详情表
function M.find_number(x, y, x1, y1)
  return ocr_req("findNumber", { x = x, y = y, x1 = x1, y1 = y1 })
end

--- 区域提取文字+数字（简单名）
function M.get_text(x, y, x1, y1)
  return ocr_req("getText", { x = x, y = y, x1 = x1, y1 = y1 })
end

function M.install()
  _G.ZiYanCV = M
  -- 默认识字不落盘截图（用户要求）；需要旧路径时设 __ZIYAN_OCR_NO_SHOT=false
  if _G.__ZIYAN_OCR_NO_SHOT == nil then
    _G.__ZIYAN_OCR_NO_SHOT = true
  end

  -- TE: pyFindMultiColor({锚点,dx,dy,色,...}, fuzzy, x1,y1,x2,y2)
  -- TS: pyFindMultiColor(0x主色, "dx|dy|0x..,...", fuzzy, x1,y1,x2,y2)
  -- 找色已由 cv.lua → ScreenBridge 接管，不再走 Python
  function pyFindMultiColor(a, b, c, d, e, f, g)
    if type(findMultiColorInRegionFuzzy) == "function" then
      return findMultiColorInRegionFuzzy(a, b, c, d, e, f, g)
    end
    return -1, -1
  end

  function pyFindColor(color, fuzzy, x1, y1, x2, y2)
    if type(findMultiColorInRegionFuzzy) == "function" then
      return findMultiColorInRegionFuzzy(
        { tonumber(color) or 0 }, fuzzy or 90,
        x1 or 0, y1 or 0, x2 or -1, y2 or -1
      )
    end
    local r = M.find_color({
      color = color, fuzzy = fuzzy or 90,
      x1 = x1 or 0, y1 = y1 or 0, x2 = x2 or -1, y2 = y2 or -1,
    })
    if r and r.ok and tonumber(r.x) and r.x >= 0 then
      return r.x, r.y
    end
    return -1, -1
  end

  function pyFindImage(template, fuzzy, x1, y1, x2, y2)
    local r = M.find_image({
      template = template, fuzzy = fuzzy or 80,
      x1 = x1 or 0, y1 = y1 or 0, x2 = x2 or -1, y2 = y2 or -1,
    })
    if r and r.ok and tonumber(r.x) and r.x >= 0 then
      return r.x, r.y
    end
    return -1, -1
  end

  function pyTap(x, y, hold_ms)
    local r = M.tap(x, y, hold_ms or 50, "file")
    return r and r.ok
  end

  function pySwipe(x1, y1, x2, y2, duration_ms)
    local r = M.swipe(x1, y1, x2, y2, duration_ms or 400, "file")
    return r and r.ok
  end

  function pySnapshot(path)
    return M.snapshot(path)
  end

  --- bid 必传（作者填写 Bundle ID），例: pyOpenApp("com.example.game")
  function pyOpenApp(bid)
    local r = M.open_app(bid)
    return r and r.ok
  end

  --- bid 必传（作者填写 Bundle ID），例: pyCloseApp("com.example.game")
  function pyCloseApp(bid)
    local r = M.close_app(bid)
    return r and r.ok
  end

  --- 区域识字：strFind(x,y,x1,y1) → 文字字符串
  function strFind(x, y, x1, y1)
    local r = M.str_find(x, y, x1, y1)
    if r and r.ok then
      return tostring(r.text or "")
    end
    return ""
  end

  function pyStrFind(x, y, x1, y1)
    return strFind(x, y, x1, y1)
  end

  --- 查找文字：findStr("登录", x,y,x1,y1) → x, y（未找到 -1,-1）
  function findStr(str, x, y, x1, y1)
    local r = M.find_str(str, x, y, x1, y1)
    if r and r.ok and tonumber(r.x) and r.x >= 0 then
      return r.x, r.y
    end
    return -1, -1
  end

  function pyFindStr(str, x, y, x1, y1)
    return findStr(str, x, y, x1, y1)
  end

  --- 查找数字：findNumber(x,y,x1,y1) → number 或 nil
  function findNumber(x, y, x1, y1)
    local r = M.find_number(x, y, x1, y1)
    if r and r.ok and r.number ~= nil then
      return r.number
    end
    return nil
  end

  function pyFindNumber(x, y, x1, y1)
    return findNumber(x, y, x1, y1)
  end

  --- 区域提取文字+数字：getText(x,y,x1,y1) → text|nil, numbers
  -- 8-161-98：对齐触动业务写法 `if result then` —— 无有效文字必须 nil（禁返回 ""）
  --  numbers 为表，如 {123, 45}；也可用 ZiYanCV.get_text 取完整 JSON
  function getText(x, y, x1, y1)
    local r = M.get_text(x, y, x1, y1)
    local nums = {}
    local text = ""
    if type(r) == "table" then
      text = tostring(r.text or "")
      if type(r.numbers) == "table" then
        nums = r.numbers
      end
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
      return nil, nums
    end
    return text, nums
  end

  function readText(x, y, x1, y1)
    return getText(x, y, x1, y1)
  end

  function pyGetText(x, y, x1, y1)
    return getText(x, y, x1, y1)
  end

  -- ---- 网络（curl，不经 Python）----
  function NetTime(timeout)
    local outf = ZIYAN_VAR .. "/.ziyan_net_time.txt"
    pcall(os.remove, outf)
    timeout = tonumber(timeout) or 8
    local urls = {
      "http://quan.suning.com/getSysTime.do",
      "http://worldtimeapi.org/api/ip",
      "https://worldtimeapi.org/api/ip",
    }
    for _, url in ipairs(urls) do
      local cmd = string.format(
        "curl -s --max-time %d '%s' > '%s' 2>/dev/null",
        timeout, url, outf
      )
      os.execute(cmd)
      local f = io.open(outf, "r")
      if f then
        local body = f:read("*a") or ""
        f:close()
        local t = body:match('"sysTime2"%s*:%s*"([^"]+)"')
            or body:match('"datetime"%s*:%s*"([^"]+)"')
            or body:match('"dateTime"%s*:%s*"([^"]+)"')
        if t and t ~= "" then
          -- worldtimeapi: 2026-07-18T17:00:00.123456+08:00 → 去 T
          t = t:gsub("T", " "):gsub("%..*$", "")
          return t
        end
      end
    end
    -- 无外网：本机时间兜底（仍返回可用字符串，避免脚本拼接 nil）
    return os.date("%Y-%m-%d %H:%M:%S")
  end

  function NetTimeStr(timeout)
    return NetTime(timeout)
  end

  function net_time(timeout)
    return NetTime(timeout)
  end

  function net_time_str(timeout)
    return NetTime(timeout)
  end

  function NetIp(timeout)
    local outf = ZIYAN_VAR .. "/.ziyan_net_ip.txt"
    local t = tonumber(timeout) or 8
    local urls = {
      "https://api.ipify.org",
      "http://ip.sb",
      "https://ifconfig.me/ip",
      "http://icanhazip.com",
    }
    for _, u in ipairs(urls) do
      pcall(os.remove, outf)
      os.execute(string.format(
        "curl -s --max-time %d '%s' > '%s' 2>/dev/null", t, u, outf))
      local f = io.open(outf, "r")
      if f then
        local ip = (f:read("*l") or ""):gsub("%s+", "")
        f:close()
        if ip:match("^%d+%.%d+%.%d+%.%d+$") or ip:match("^[%x:]+$") then
          return ip
        end
      end
    end
    return ""
  end

  function net_ip(timeout)
    return NetIp(timeout)
  end

  --- HTTP GET：返回 body 字符串；失败返回 ""
  function httpGet(url, timeout)
    url = tostring(url or "")
    if url == "" then return "" end
    local outf = ZIYAN_VAR .. "/.ziyan_http_get_body.txt"
    local t = tonumber(timeout) or 12
    pcall(os.remove, outf)
    os.execute(string.format(
      "curl -sL --max-time %d '%s' > '%s' 2>/dev/null", t, url:gsub("'", ""), outf))
    local f = io.open(outf, "r")
    if not f then return "" end
    local body = f:read("*a") or ""
    f:close()
    return body
  end

  function HttpGet(url, timeout)
    return httpGet(url, timeout)
  end

  -- embed 覆盖了 os.execute，但 libc io.popen 在 iOS 上会挂死 framecap。
  -- 探测 curl 只能走 file_exists，禁止 command -v / popen。
  local function ftp_curl_bin()
    local cands = {
      "/var/jb/usr/bin/curl",
      "/usr/bin/curl",
      "/usr/local/bin/curl",
      "/bin/curl",
    }
    for i = 1, #cands do
      if file_exists(cands[i]) then return cands[i] end
    end
    return nil
  end

  local function ftp_have_curl()
    return ftp_curl_bin() ~= nil
  end

  local function ftp_python()
    local cands = {
      ZIYAN_ROOT .. "/bin/python3.7",
      "/var/jb/usr/lib/ziyan/bin/python3.7",
      "/usr/lib/ziyan/bin/python3.7",
      "/usr/bin/python3",
    }
    for i = 1, #cands do
      if file_exists(cands[i]) then return cands[i] end
    end
    return nil
  end

  -- 西部数码/万网 PASV 常回内网 IP，rootful 无 curl 时 ftplib 会连错数据口。
  -- 禁止 io.popen（iOS embed 会挂 framecap）；错误写 ZIYAN_VAR 再读。
  local function ftp_err_path()
    return ZIYAN_VAR .. "/.ziyan_ftp_err.txt"
  end

  local function ftp_read_err()
    local f = io.open(ftp_err_path(), "r")
    if not f then return "" end
    local t = f:read("*a") or ""
    f:close()
    t = t:gsub("\r", ""):gsub("%s+$", "")
    local last = t:match("([^\n]+)$") or t
    if last:find("530") then return "530 Login incorrect" end
    if last:find("Access denied") then return "530 Login incorrect" end
    return last
  end

  -- curl 被动模式：忽略服务器广告的 PASV IP，数据连接仍走控制连接主机。
  local function ftp_curl_flags(timeout)
    return string.format(
      "--connect-timeout %d --max-time %d --ftp-pasv --ftp-skip-pasv-ip -sS",
      math.min(12, tonumber(timeout) or 30), tonumber(timeout) or 30)
  end

  local function ftp_via_py(op, host, user, password, a, b, port, timeout)
    local py = ftp_python()
    if not py then
      return { ok = false, error = "CAPABILITY_MISSING", via = "no_curl_no_python" }
    end
    local helper = ZIYAN_VAR .. "/.ziyan_ftp_cli.py"
    local need = true
    local hf0 = io.open(helper, "r")
    if hf0 then
      local head = hf0:read(80) or ""
      hf0:close()
      if head:find("skip_pasv_ip", 1, true) then need = false end
    end
    if need then
      local hf = io.open(helper, "w")
      if not hf then return { ok = false, error = "ftp_helper_write" } end
      hf:write([[
# skip_pasv_ip
import sys, ftplib
op, host, user, password, a, b, port, timeout = sys.argv[1:9]
port = int(port); timeout = float(timeout)
class FTP(ftplib.FTP):
    def makepasv(self):
        _h, p = ftplib.FTP.makepasv(self)
        return self.host, p
ftp = FTP()
ftp.connect(host, port, timeout=timeout)
ftp.login(user, password)
if op == "upload":
    with open(a, "rb") as f: ftp.storbinary("STOR " + b, f)
elif op == "download":
    with open(b, "wb") as f: ftp.retrbinary("RETR " + a, f.write)
elif op == "delete":
    ftp.delete(a)
elif op == "size":
    print(ftp.size(a) or "")
ftp.quit()
]])
      hf:close()
    end
    local errf = ftp_err_path()
    pcall(os.remove, errf)
    local cmd = string.format(
      "'%s' '%s' '%s' '%s' '%s' '%s' '%s' '%s' '%s' '%s' >'%s' 2>&1",
      py, helper, op, tostring(host or ""), tostring(user or ""),
      tostring(password or ""), tostring(a or ""), tostring(b or ""),
      tostring(port or 21), tostring(timeout or 30), errf)
    local st = os.execute(cmd)
    local ok = (st == true or st == 0)
    local err = ftp_read_err()
    if ok then return { ok = true, via = "python_ftplib" } end
    return { ok = false, via = "python_ftplib", error = (err ~= "" and err or "ftp_fail") }
  end

  function FtpUpload(host, user, password, local_path, remote_path, port, timeout)
    port = port or 21
    timeout = tonumber(timeout) or 30
    local curl = ftp_curl_bin()
    if curl then
      local errf = ftp_err_path()
      pcall(os.remove, errf)
      local cmd = string.format(
        "'%s' %s -T '%s' --user '%s:%s' 'ftp://%s:%d/%s' >'%s' 2>&1",
        curl, ftp_curl_flags(timeout), tostring(local_path or ""),
        tostring(user or ""), tostring(password or ""),
        tostring(host or ""), port, tostring(remote_path or ""), errf
      )
      local st = os.execute(cmd)
      local ok = (st == true or st == 0)
      if ok then return { ok = true, via = "curl" } end
      return { ok = false, via = "curl", error = ftp_read_err() }
    end
    return ftp_via_py("upload", host, user, password, local_path, remote_path, port, timeout)
  end

  function FtpDownload(host, user, password, remote_path, local_path, port, timeout)
    port = port or 21
    timeout = tonumber(timeout) or 30
    local curl = ftp_curl_bin()
    if curl then
      local errf = ftp_err_path()
      pcall(os.remove, errf)
      local cmd = string.format(
        "'%s' %s --user '%s:%s' 'ftp://%s:%d/%s' -o '%s' >'%s' 2>&1",
        curl, ftp_curl_flags(timeout), tostring(user or ""), tostring(password or ""),
        tostring(host or ""), port, tostring(remote_path or ""),
        tostring(local_path or ""), errf
      )
      local st = os.execute(cmd)
      local ok = (st == true or st == 0)
      if ok then return { ok = true, via = "curl" } end
      return { ok = false, via = "curl", error = ftp_read_err() }
    end
    return ftp_via_py("download", host, user, password, remote_path, local_path, port, timeout)
  end

  function FtpDelete(host, user, password, remote_path, port, timeout)
    port = port or 21
    timeout = tonumber(timeout) or 30
    local curl = ftp_curl_bin()
    if curl then
      local errf = ftp_err_path()
      pcall(os.remove, errf)
      local cmd = string.format(
        "'%s' %s --user '%s:%s' -Q 'DELE %s' 'ftp://%s:%d/' >'%s' 2>&1",
        curl, ftp_curl_flags(timeout), tostring(user or ""), tostring(password or ""),
        tostring(remote_path or ""), tostring(host or ""), port, errf
      )
      local st = os.execute(cmd)
      local ok = (st == true or st == 0)
      if ok then return { ok = true, via = "curl" } end
      return { ok = false, via = "curl", error = ftp_read_err() }
    end
    return ftp_via_py("delete", host, user, password, remote_path, "", port, timeout)
  end

  function FtpRead(host, user, password, remote_path, port, timeout)
    local tmp = ZIYAN_VAR .. "/.ziyan_ftp_read.tmp"
    local r = FtpDownload(host, user, password, remote_path, tmp, port, timeout)
    if not (r and r.ok) then return { ok = false, error = r and r.error } end
    local f = io.open(tmp, "rb")
    if not f then return { ok = false } end
    local data = f:read("*a") or ""
    f:close()
    return { ok = true, data = data, text = data, size = #data }
  end

  function FtpIsUpdate(host, user, password, remote_path, local_path, port, timeout)
    port = port or 21
    timeout = tonumber(timeout) or 30
    local tmp = ZIYAN_VAR .. "/.ziyan_ftp_size.txt"
    pcall(os.remove, tmp)
    local curl = ftp_curl_bin()
    local remote_sz = nil
    if curl then
      local cmd = string.format(
        "'%s' %s -I --user '%s:%s' 'ftp://%s:%d/%s' 2>/dev/null | tr -d '\\r' > '%s'",
        curl, ftp_curl_flags(timeout), tostring(user or ""), tostring(password or ""),
        tostring(host or ""), port, tostring(remote_path or ""), tmp
      )
      os.execute(cmd)
      local hf = io.open(tmp, "r")
      if hf then
        for line in hf:lines() do
          local n = line:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
          if n then remote_sz = tonumber(n); break end
        end
        hf:close()
      end
    end
    if not remote_sz and curl then
      -- SIZE 命令回退
      local cmd2 = string.format(
        "'%s' %s --user '%s:%s' -Q 'SIZE %s' 'ftp://%s:%d/' 2>/dev/null | tr -cd '0-9' > '%s'",
        curl, ftp_curl_flags(timeout), tostring(user or ""), tostring(password or ""),
        tostring(remote_path or ""), tostring(host or ""), port, tmp
      )
      os.execute(cmd2)
      local sf = io.open(tmp, "r")
      if sf then
        remote_sz = tonumber(sf:read("*a") or "")
        sf:close()
      end
    end
    if not remote_sz and not ftp_have_curl() then
      local py = ftp_python()
      if py then
        ftp_via_py("size", host, user, password, remote_path, "", port, timeout)
        local outf = ZIYAN_VAR .. "/.ziyan_ftp_size_py.txt"
        local cmd3 = string.format(
          "'%s' '%s' size '%s' '%s' '%s' '%s' '' '%s' '%s' > '%s' 2>/dev/null",
          py, ZIYAN_VAR .. "/.ziyan_ftp_cli.py",
          tostring(host or ""), tostring(user or ""), tostring(password or ""),
          tostring(remote_path or ""), tostring(port), tostring(timeout), outf)
        os.execute(cmd3)
        local pf = io.open(outf, "r")
        if pf then
          remote_sz = tonumber(pf:read("*a") or "")
          pf:close()
        end
      end
    end
    local local_sz = 0
    if type(local_path) == "string" and local_path ~= "" then
      local lf = io.open(local_path, "rb")
      if lf then local_sz = lf:seek("end") or 0; lf:close() end
    end
    if not remote_sz then
      return { ok = false, updated = false, error = "no_remote_size" }
    end
    local updated = (local_sz ~= remote_sz)
    return { ok = true, updated = updated, remote_size = remote_sz, local_size = local_sz }
  end

  FtpIsUpdated = FtpIsUpdate
  ftp_upload = FtpUpload
  ftp_download = FtpDownload
  ftp_delete = FtpDelete
  ftp_read = FtpRead
  ftp_is_update = FtpIsUpdate

  -- ---- 剪贴板 / 文件 / PLIST（纯 Lua / shell，不经 Python）----
  function CopyClipboard(text)
    text = tostring(text or "")
    local f = io.open(ZIYAN_VAR .. "/.ziyan_clipboard", "w")
    if not f then return false end
    f:write(text)
    f:close()
    -- 尝试 UIPasteboard（若引擎提供）
    if type(writePasteboard) == "function" then
      pcall(writePasteboard, text)
    end
    return true
  end

  function PasteClipboard()
    if type(readPasteboard) == "function" and readPasteboard ~= PasteClipboard then
      local ok, s = pcall(readPasteboard)
      if ok and s then return tostring(s) end
    end
    local f = io.open(ZIYAN_VAR .. "/.ziyan_clipboard", "r")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return s
  end

  SetClipboard = CopyClipboard
  GetClipboard = PasteClipboard
  copy_clipboard = CopyClipboard
  paste_clipboard = PasteClipboard

  function FileExists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
  end

  function FileCreate(path, content, is_dir)
    if type(path) ~= "string" or path == "" then return false end
    if is_dir then
      return os.execute(string.format('mkdir -p "%s"', path)) == true
          or os.execute(string.format('mkdir -p "%s"', path)) == 0
    end
    local dir = path:match("(.+)/[^/]+$")
    if dir then os.execute(string.format('mkdir -p "%s"', dir)) end
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(content or "")
    f:close()
    return true
  end

  function FileCopy(src, dst)
    return os.execute(string.format('cp -f "%s" "%s"', tostring(src), tostring(dst))) == true
        or os.execute(string.format('cp -f "%s" "%s"', tostring(src), tostring(dst))) == 0
  end

  function FileDelete(path)
    if type(path) ~= "string" or path == "" then return false end
    if os.remove(path) then return true end
    local st = os.execute(string.format('rm -rf "%s" 2>/dev/null', path))
    return st == true or st == 0
  end

  function FileMove(src, dst)
    if os.rename(src, dst) then return true end
    local st = os.execute(string.format('mv "%s" "%s" 2>/dev/null', tostring(src), tostring(dst)))
    return st == true or st == 0
  end

  function FileList(path, recursive)
    local outf = ZIYAN_VAR .. "/.ziyan_filelist.txt"
    local cmd
    if recursive then
      cmd = string.format('find "%s" -type f 2>/dev/null > "%s"', tostring(path), outf)
    else
      cmd = string.format('ls -1 "%s" 2>/dev/null > "%s"', tostring(path), outf)
    end
    os.execute(cmd)
    local items = {}
    local f = io.open(outf, "r")
    if f then
      for line in f:lines() do
        if line ~= "" then items[#items + 1] = line end
      end
      f:close()
    end
    return items
  end

  FileWalk = FileList
  file_exists = FileExists
  file_create = FileCreate
  file_copy = FileCopy
  file_delete = FileDelete
  file_move = FileMove
  file_list = FileList

  -- 内存缓存是 ZiYan 自身业务状态，不应依赖设备侧 Python + plistlib。
  -- rootless Python 曾误链 rootful libpython，部分 rootful 机又缺 libexpat，
  -- 使完全相同的 MemoryWrite 在不同机器无故失败。新缓存优先纯 Lua JSON；
  -- 旧 plist 仅作为迁移回退，确保已有数据不会被直接丢弃。
  local function mem_cache_name(bid)
    local s = tostring(bid or "default")
    return (s:gsub("[^%w%._%-]", "_"))
  end

  local function mem_json_path(bid)
    return ZIYAN_VAR .. "/memory/" .. mem_cache_name(bid) .. ".json"
  end

  local function mem_plist_path(bid)
    return ZIYAN_VAR .. "/memory/" .. tostring(bid or "default") .. ".plist"
  end

  local function mem_cache_read(bid)
    local jf, _, jcode = io.open(mem_json_path(bid), "r")
    if jf then
      local body = jf:read("*a")
      local closed = jf:close()
      if not body or not closed then return nil, "memory_json_unreadable" end
      local ok, obj = pcall(json_decode, body)
      if ok and type(obj) == "table" then return obj end
      return nil, "memory_json_invalid"
    end
    if jcode ~= 2 then return nil, "memory_json_unreadable" end
    local path = mem_plist_path(bid)
    local f, _, code = io.open(path, "rb")
    if not f then
      if code == 2 then return {} end
      return nil, "memory_plist_unreadable"
    end
    f:close()
    -- PlistRead owns a unique output and checks the native helper exit status.
    local ok, obj = pcall(PlistRead, path)
    if ok and type(obj) == "table" then return obj end
    return nil, "memory_plist_invalid"
  end

  local function mem_cache_write(bid, tbl)
    os.execute(string.format('mkdir -p "%s/memory"', ZIYAN_VAR))
    local path = mem_json_path(bid)
    local encoded, body = pcall(json_encode, tbl)
    if not encoded then return false end
    local made, reservation = pcall(os.tmpname)
    if not made then return false end
    local tmpj = path .. "." .. reservation:match("[^/\\]+$") .. ".tmp"
    local f = io.open(tmpj, "wb")
    if not f then os.remove(reservation); return false end
    local wrote = f:write(body)
    local closed = f:close()
    local committed = wrote and closed and os.rename(tmpj, path)
    os.remove(reservation)
    if committed then return true end
    os.remove(tmpj)
    return false
  end

  function PlistRead(path)
    if type(path) ~= "string" or path == "" then return nil end
    local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
    local made, outf = pcall(os.tmpname)
    if not made then return nil end
    local ok, st = pcall(os.execute, quote(ZIYAN_ROOT .. "/bin/ziyan_plist")
      .. " read " .. quote(path) .. " " .. quote(outf) .. " 2>/dev/null")
    if not ok or not (st == true or st == 0) then
      os.remove(outf)
      return nil
    end
    local f = io.open(outf, "r")
    if not f then os.remove(outf); return nil end
    local body = f:read("*a") or ""
    f:close()
    os.remove(outf)
    local ok, obj = pcall(json_decode, body)
    if ok then return obj end
    return nil
  end

  function PlistWrite(path, data)
    if type(path) ~= "string" or path == "" then return false end
    local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
    local encoded, body = pcall(json_encode, type(data) == "table" and data or { value = data })
    if not encoded then return false end
    local made, tmpj = pcall(os.tmpname)
    if not made then return false end
    local f = io.open(tmpj, "w")
    if not f then os.remove(tmpj); return false end
    local wrote = f:write(body)
    local closed = f:close()
    local ok, st = false, nil
    if wrote and closed then
      ok, st = pcall(os.execute, quote(ZIYAN_ROOT .. "/bin/ziyan_plist")
        .. " write " .. quote(tmpj) .. " " .. quote(path) .. " 2>/dev/null")
    end
    os.remove(tmpj)
    return ok and (st == true or st == 0)
  end

  plist_read = PlistRead
  plist_write = PlistWrite

  -- ---- 内存读取（缓存 plist + Hook / ziyan_mem）----
  function MemoryAccess(Bunid_str, str)
    local bid = tostring(Bunid_str or "")
    local key = tostring(str or "")
    local cache, err = mem_cache_read(bid)
    if not cache then return nil, err end
    if cache[key] ~= nil then
      return tostring(cache[key])
    end
    -- 常见别名
    for k, v in pairs(cache) do
      if tostring(k):lower() == key:lower() then
        return tostring(v)
      end
    end
    local arr = MemoryFind(bid, key)
    if type(arr) == "table" and arr[1] then
      return tostring(arr[1])
    end
    return ""
  end

  function memory_access(Bunid_str, str)
    return MemoryAccess(Bunid_str, str)
  end

  function MemoryWrite(Bunid_str, str, value)
    local bid = tostring(Bunid_str or "")
    local key = tostring(str or "")
    if bid == "" or key == "" then return false end
    local cache, err = mem_cache_read(bid)
    if not cache then return false, err end
    cache[key] = tostring(value)
    return mem_cache_write(bid, cache)
  end

  function memory_write(Bunid_str, str, value)
    return MemoryWrite(Bunid_str, str, value)
  end

  function MemoryKeys(Bunid_str)
    local bid = tostring(Bunid_str or "")
    local cache, err = mem_cache_read(bid)
    if not cache then return { ok = false, error = err, keys = {} } end
    local keys = {}
    for k, _ in pairs(cache) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    return { ok = true, keys = keys, sources = { "cache_json" }, path = mem_json_path(bid) }
  end

  function memory_keys(Bunid_str)
    return MemoryKeys(Bunid_str)
  end

  function MemoryDump(Bunid_str, max_items)
    local bid = tostring(Bunid_str or "")
    local cache, err = mem_cache_read(bid)
    if not cache then return { ok = false, error = err, items = {}, count = 0 } end
    local items = {}
    max_items = tonumber(max_items) or 200
    for k, v in pairs(cache) do
      items[#items + 1] = { key = tostring(k), value = tostring(v) }
      if #items >= max_items then break end
    end
    return { ok = true, items = items, count = #items }
  end

  function memory_dump(Bunid_str, max_items)
    return MemoryDump(Bunid_str, max_items)
  end

  --- MemoryFind：优先读 MemHook 快照，再回退 ziyan_mem CLI
  function MemoryFind(Bunid_str, str)
    local bid = tostring(Bunid_str or "")
    local q = tostring(str or "")
    local t = {}

    -- 触发 hook 刷新
    local req = ZIYAN_VAR .. "/.ziyan_mem_req"
    local f = io.open(req, "w")
    if f then
      f:write("find\n" .. bid .. "\n" .. q .. "\n")
      f:close()
      if type(mSleep) == "function" then mSleep(80) end
    end

    local snap = ZIYAN_VAR .. "/memory/hook_snapshot.json"
    local sf = io.open(snap, "r")
    if sf then
      local body = sf:read("*a") or ""
      sf:close()
      local obj = json_decode(body)
      if type(obj) == "table" then
        local function push(s)
          s = tostring(s or "")
          if s ~= "" then t[#t + 1] = s end
        end
        if q == "角色" or q == "role" then
          if obj.roleName or obj.name then push("名称:" .. tostring(obj.roleName or obj.name)) end
          if obj.roleAtt or obj.attack then push("攻击:" .. tostring(obj.roleAtt or obj.attack)) end
          if obj.roleLevel or obj.level then push("等级:" .. tostring(obj.roleLevel or obj.level)) end
        elseif q == "排行榜" or q == "rank" then
          local ranks = obj.ranks or obj.rank or obj.list
          if type(ranks) == "table" then
            for _, row in ipairs(ranks) do
              if type(row) == "string" then push(row)
              elseif type(row) == "table" then
                push(table.concat({
                  tostring(row.rank or row[1] or ""),
                  tostring(row.name or row[2] or ""),
                  tostring(row.guild or row[3] or ""),
                }, "|"))
              end
            end
          end
        elseif q == "背包" or q == "bag" then
          local items = obj.bag or obj.items or obj.inventory
          if type(items) == "table" then
            for _, it in ipairs(items) do
              if type(it) == "string" then push(it)
              elseif type(it) == "table" then push(tostring(it.name or it[1] or "")) end
            end
          end
        elseif type(obj.texts) == "table" then
          for _, s in ipairs(obj.texts) do push(s) end
        end
      end
    end

    if #t > 0 then return t end

    -- CLI 回退
    local outf = ZIYAN_VAR .. "/.ziyan_mem_out.json"
    pcall(os.remove, outf)
    local mode = "find"
    if q == "角色" or q == "role" then mode = "role" end
    local cmd = string.format(
      "/usr/lib/ziyan/bin/ziyan_mem %s '%s' '%s' > '%s' 2>/dev/null",
      mode, bid, q, outf
    )
    os.execute(cmd)
    local rf = io.open(outf, "r")
    if rf then
      local body = rf:read("*a") or ""
      rf:close()
      local obj = json_decode(body)
      if type(obj) == "table" then
        if type(obj.texts) == "table" then
          for _, s in ipairs(obj.texts) do
            if tostring(s) ~= "" then t[#t + 1] = tostring(s) end
          end
        elseif obj.name then
          t[1] = "名称:" .. tostring(obj.name)
        end
      end
    end
    return t
  end

  function memory_find(Bunid_str, str)
    return MemoryFind(Bunid_str, str)
  end

  function MemoryScanNames(Bunid_str)
    local r = MemoryKeys(Bunid_str)
    if not r.ok then return {ok=false, error=r.error, names={}, items={}} end
    local names = (r and r.keys) or {}
    local items = {}
    for _, k in ipairs(names) do
      local value, err = MemoryAccess(Bunid_str, k)
      if value == nil then return {ok=false, error=err, names={}, items={}} end
      items[#items + 1] = { name = k, value = value }
    end
    return { ok = true, names = names, items = items }
  end

  function MemoryRoleName(Bunid_str, hint)
    local t = MemoryFind(Bunid_str, "角色")
    for _, s in ipairs(t or {}) do
      local name = tostring(s):match("名称:(.+)")
      if name and name ~= "" then return name end
    end
    return ""
  end

  function memory_role_name(Bunid_str, hint)
    return MemoryRoleName(Bunid_str, hint)
  end

  return M
end

return M
