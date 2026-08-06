--[[ Result Verification Model（结果验证模型）
  流程：截图/指纹 → 动作 → 同步 → 再指纹 → 判断 → 记录
  禁止：点击后默认成功；login 相位下「钮变暗」不算离开登录。
]]
local M = { module = "verify", version = "1.1.0", model = "ResultVerification" }

local function defined(n) return type(_G[n]) == "function" end

local function sleep(ms)
  if defined("mSleep") then mSleep(ms) else os.execute(string.format("sleep %.3f", (ms or 0) / 1000)) end
end

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then return _G.ZIYAN_VAR end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then return "/var/jb/usr/lib/ziyan/var" end
  return "/usr/lib/ziyan/var"
end

local function media_dir()
  return "/private/var/mobile/Media/ZiYan"
end

local function stuck_gate(ph)
  ph = tostring(ph or "")
  return ph == "login" or ph == "privacy"
end

--- 画面指纹：相位 + 若干采样点色（轻量）
function M.fingerprint(bid)
  bid = bid or _G.__ZIYAN_LAST_BID
  if defined("syncScreen") then
    pcall(syncScreen, _G.__ZIYAN_ORIENT or 1, bid)
  elseif defined("screenSync") then
    pcall(screenSync, _G.__ZIYAN_ORIENT or 1, bid)
  end
  local ph = "?"
  if defined("gamePhase") then
    ph = tostring(gamePhase(bid) or "?")
  elseif defined("gameDetectState") then
    ph = tostring(gameDetectState(bid) or "?")
  end
  local front = "?"
  if defined("frontAppBid") then front = tostring(frontAppBid() or "?") end
  local w, h = 1136, 640
  if defined("screenSize") then w, h = screenSize()
  elseif defined("getScreenSize") then w, h = getScreenSize() end
  local samples = {}
  local pts = {
    { 0.50, 0.50 }, { 0.64, 0.73 }, { 0.50, 0.78 }, { 0.20, 0.20 }, { 0.80, 0.20 },
  }
  if defined("getColor") then
    for _, p in ipairs(pts) do
      local x = math.floor(w * p[1])
      local y = math.floor(h * p[2])
      samples[#samples + 1] = { x = x, y = y, c = tonumber(getColor(x, y)) or 0 }
    end
  end
  return {
    bid = tostring(bid or ""),
    front = front,
    phase = ph,
    w = w, h = h,
    samples = samples,
    ts = os.time(),
  }
end

local function color_delta(a, b)
  a, b = tonumber(a) or 0, tonumber(b) or 0
  local ar, ag, ab = math.floor(a / 0x10000) % 256, math.floor(a / 0x100) % 256, a % 256
  local br, bg, bb = math.floor(b / 0x10000) % 256, math.floor(b / 0x100) % 256, b % 256
  return math.abs(ar - br) + math.abs(ag - bg) + math.abs(ab - bb)
end

--- 比较前后指纹
-- login/privacy：必须相位离开才算成功；钮变暗的纯色差一律忽略
function M.changed(before, after, min_color_delta)
  min_color_delta = tonumber(min_color_delta) or 80
  if not before or not after then return false, "missing_fp" end
  if before.front ~= after.front and tostring(after.front) ~= tostring(before.bid)
      and tostring(after.front) ~= "" and tostring(after.front) ~= "?" then
    -- 前台离开目标包：不算登录成功
    if stuck_gate(before.phase) then
      return false, "front_left_game:" .. tostring(after.front)
    end
    return true, "front:" .. tostring(before.front) .. "->" .. tostring(after.front)
  end
  if before.phase ~= after.phase then
    if before.phase == "login" then
      if stuck_gate(after.phase) or after.phase == "boot" or after.phase == "unknown" then
        return false, "still_auth_gate:" .. tostring(after.phase)
      end
      return true, "left_login->" .. tostring(after.phase)
    end
    if before.phase == "privacy" then
      -- privacy→login 算推进；仍 privacy 不算
      if after.phase == "privacy" then return false, "still_privacy" end
      return true, "left_privacy->" .. tostring(after.phase)
    end
    return true, "phase:" .. tostring(before.phase) .. "->" .. tostring(after.phase)
  end
  -- 同相位：login/privacy 禁止用色差冒充成功
  if stuck_gate(before.phase) then
    return false, "still_" .. tostring(before.phase)
  end
  local bs, as = before.samples or {}, after.samples or {}
  local n = math.min(#bs, #as)
  local hits = 0
  for i = 1, n do
    if color_delta(bs[i].c, as[i].c) >= min_color_delta then
      hits = hits + 1
    end
  end
  if hits >= 2 then
    return true, "color_hits=" .. hits
  end
  return false, "no_change"
end

function M.snapshot(tag)
  tag = tostring(tag or "verify"):gsub("[^%w_%-]", "_")
  local path = media_dir() .. "/_verify_" .. tag .. ".png"
  if defined("snapshot") then
    pcall(snapshot, path)
    return path
  end
  if defined("screenDump") then
    pcall(screenDump, path)
    return path
  end
  return nil
end

--- 失败报告：截图状态 → 原因 → 模块 → 方案
function M.fail_report(opts)
  opts = opts or {}
  local shot = opts.shot
  if not shot and not _G.__ZIYAN_OCR_NO_SHOT then
    shot = M.snapshot(opts.tag or "fail")
  end
  local lines = {
    "FAIL_REPORT",
    "ts=" .. os.date("%Y-%m-%d %H:%M:%S"),
    "bid=" .. tostring(opts.bid or _G.__ZIYAN_LAST_BID or ""),
    "phase=" .. tostring(opts.phase or ""),
    "front=" .. tostring(opts.front or ""),
    "shot=" .. tostring(shot or ""),
    "reason=" .. tostring(opts.reason or "unknown"),
    "module=" .. tostring(opts.module or "verify"),
    "fix=" .. tostring(opts.fix or "reanalyze / adjust sync map / stop repeat tap"),
  }
  local body = table.concat(lines, "\n") .. "\n"
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_fail_report.txt", "w")
    if f then f:write(body); f:close() end
  end)
  pcall(function()
    local f = io.open(media_dir() .. "/.ziyan_fail_report.txt", "w")
    if f then f:write(body); f:close() end
  end)
  if defined("learnError") then
    learnError({
      type = "fail_report",
      module = tostring(opts.module or "verify"),
      cause = tostring(opts.reason or ""),
      fix = tostring(opts.fix or ""),
    })
  end
  return body, shot
end

--- 验证推进：等待 → 同步 → 指纹 → 判断
function M.after(bid, before, label, wait_ms)
  wait_ms = tonumber(wait_ms) or 1200
  sleep(wait_ms)
  local path = nil
  if not _G.__ZIYAN_OCR_NO_SHOT then
    path = M.snapshot(tostring(label or "act"))
  end
  local after = M.fingerprint(bid)
  local ok, reason = M.changed(before, after)
  if defined("learnRecord") then
    learnRecord({
      bid = bid, state = after.phase, action = "verify:" .. tostring(label),
      ok = ok, detail = tostring(reason) .. (path and (" shot=" .. path) or ""),
    })
  end
  if not ok then
    if defined("learnError") then
      learnError({
        type = "verify_fail", module = "verify",
        cause = tostring(label) .. " " .. tostring(reason),
        fix = "phase must leave gate; ignore button-dim color delta",
      })
    end
    M.fail_report({
      bid = bid, phase = after.phase, front = after.front, shot = path,
      reason = tostring(label) .. ":" .. tostring(reason),
      module = "verify",
      fix = stuck_gate(after.phase)
        and "auth/credential or alternate login path; do not re-tap same gold"
        or "retarget via screen_sync / update state classify",
      tag = tostring(label or "fail"),
    })
  end
  pcall(function()
    local f = io.open(var_dir() .. "/.ziyan_verify_log.txt", "a")
    if f then
      f:write(string.format("%s label=%s ok=%s reason=%s before=%s after=%s\n",
        os.date("%H:%M:%S"), tostring(label), tostring(ok), tostring(reason),
        tostring(before and before.phase), tostring(after.phase)))
      f:close()
    end
  end)
  return ok, after, reason
end

function M.act(bid, label, act_fn, wait_ms)
  local before = M.fingerprint(bid)
  if type(act_fn) == "function" then
    pcall(act_fn)
  end
  return M.after(bid, before, label, wait_ms)
end

function M.install(engine)
  _G.verifyFingerprint = function(bid) return M.fingerprint(bid) end
  _G.verifyAfter = function(bid, before, label, wait_ms) return M.after(bid, before, label, wait_ms) end
  _G.verifyAct = function(bid, label, act_fn, wait_ms) return M.act(bid, label, act_fn, wait_ms) end
  _G.verifyFailReport = function(opts) return M.fail_report(opts) end
  _G.ZiYanVerify = M
  if engine then engine.verify = M end
  return M
end

return M
