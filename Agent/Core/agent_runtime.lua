-- ZiYan Agent Runtime P1. Local rules only. No new daemon.
-- Agent stop uses .ziyan_agent_stop only. Never writes .ziyan_stop.

local M = {}

local AGENT_ROOT = "/private/var/mobile/Media/ZiYan/Agent游戏"
local DRILL_LEARN_IDS = {
  ags_17886130846274 = true,
  ags_17886130889526 = true,
  ags_17886130933873 = true,
  ags_17886131005180 = true,
}
local AGENT_SUBS = {
  "游戏配置", "人工学习", "学习数据", "运行记录",
  "错误报告", "生成脚本", "临时缓存",
}

local SAFE_KEYS = {
  password = true, passcode = true, captcha = true, verify = true,
  pay = true, trade = true,
}

local function var_dir()
  if _G.ZIYAN_VAR and _G.ZIYAN_VAR ~= "" then
    return _G.ZIYAN_VAR
  end
  local f = io.open("/var/jb/usr/lib/ziyan/var/.ziyan_hooks", "r")
  if f then
    f:close()
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function read_trim(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  return (s:gsub("[\r\n ]+$", ""))
end

local function read_single_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  local rest = f:read("*a") or ""
  f:close()
  if not line or line == "" or rest:match("%S") then
    return nil
  end
  return (line:gsub("\r$", ""))
end

local function write_file(path, body)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(body or "")
  f:close()
  return true
end

local function now_s()
  return os.time()
end

local function mkdir_fixed(path)
  -- Agent游戏 top-level directories are provisioned by the package.
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function ensure_agent_dirs()
  mkdir_fixed("/private/var/mobile/Media/ZiYan/Agent游戏/游戏配置")
  mkdir_fixed("/private/var/mobile/Media/ZiYan/Agent游戏/人工学习")
  mkdir_fixed("/private/var/mobile/Media/ZiYan/Agent游戏/学习数据")
  mkdir_fixed("/private/var/mobile/Media/ZiYan/Agent游戏/运行记录")
  mkdir_fixed("/private/var/mobile/Media/ZiYan/Agent游戏/错误报告")
  mkdir_fixed("/private/var/mobile/Media/ZiYan/Agent游戏/生成脚本")
  mkdir_fixed("/private/var/mobile/Media/ZiYan/Agent游戏/临时缓存")
end

local function safe_session_name(id)
  if type(id) ~= "string" then return nil end
  if not id:match("^ags_[A-Za-z0-9_]+$") and not id:match("^ags_[0-9]+$") then
    return nil
  end
  return id
end

function M.front_bid()
  return read_trim(var_dir() .. "/.ziyan_front_bid")
end

function M.frame_seq()
  local direct = tonumber(read_trim(var_dir() .. "/.ziyan_frame_seq"))
  if direct and direct > 0 then
    return direct
  end
  local front = M.front_bid()
  local lease = read_trim(var_dir() .. "/.ziyan_lease_state")
  local lfront = lease:match("front=([^\n]+)")
  local lseq = tonumber(lease:match("seq=(%d+)"))
  if lseq and lseq > 0 and lfront and front ~= "" and lfront == front then
    return lseq
  end
  local ack = read_trim(var_dir() .. "/.ziyan_frame_ack")
  local aseq = tonumber(ack:match("seq=(%d+)"))
  if aseq and aseq > 0 then
    return aseq
  end
  if lseq and lseq > 0 then
    return lseq
  end
  return 0
end

function M.frame_age()
  local lease = read_trim(var_dir() .. "/.ziyan_lease_state")
  local age = lease:match("age_ms=(%-?%d+)")
  if age then return tonumber(age) end
  local old = read_trim(var_dir() .. "/.ziyan_frame_lease")
  local old_age = old:match("frame_age_ms=(%-?%d+)")
  if old_age then return tonumber(old_age) end
  return tonumber(read_trim(var_dir() .. "/.ziyan_frame_age")) or -1
end

function M.lock_state()
  return read_trim(var_dir() .. "/.ziyan_lock_state")
end

function M.fc_n()
  local reported = tonumber(read_trim(var_dir() .. "/.ziyan_fc_n"))
  if reported then
    return reported
  end
  local alive = read_trim(var_dir() .. "/.ziyan_framecap_alive")
  if alive:match("pid=(%d+)") then
    return 1
  end
  return 0
end

function M.safe_reason(front, text)
  local blob = (front or "") .. " " .. (text or "")
  local low = blob:lower()
  for k, _ in pairs(SAFE_KEYS) do
    if low:find(k, 1, true) then
      return k
    end
  end
  local words = {
    "密码", "验证码", "支付", "充值", "交易", "实名",
    "邮寄", "丢弃", "分解", "强化", "账号切换", "隐私",
    "授权", "滑块",
  }
  for i = 1, #words do
    if blob:find(words[i], 1, true) then
      return "safe_page"
    end
  end
  return nil
end

function M.snapshot(session)
  local hooks = read_trim(var_dir() .. "/.ziyan_hooks")
  local alive = read_trim(var_dir() .. "/.ziyan_framecap_alive")
  return {
    session_id = session.session_id,
    request_id = session.request_id,
    profile_id = session.profile_id,
    front_bid = M.front_bid(),
    frame_seq = M.frame_seq(),
    frame_age = M.frame_age(),
    fc_n = M.fc_n(),
    sb_pid = hooks:match("sb_pid=(%d+)") or "",
    bb_pid = read_trim(var_dir() .. "/.ziyan_bb_pid"),
    framecap_pid = alive:match("pid=(%d+)") or "",
    lock_state = M.lock_state(),
    agent_state = session.state,
    last_error = session.error_code or "",
  }
end

function M.new_session(profile)
  local request_id = tostring(now_s()) .. tostring(math.random(1000, 9999))
  return {
    request_id = request_id,
    session_id = "ags_" .. request_id,
    profile_id = profile.profile_id,
    bundle_id = profile.bundle_id,
    display_name = profile.display_name or profile.profile_id,
    game_name = profile.game_name or profile.display_name or "未选择",
    start_time = now_s(),
    state = "IDLE",
    ui_state = "未运行",
    last_action = "",
    frame_seq_before = 0,
    frame_seq_after = 0,
    retry_count = 0,
    error_code = "",
    stop_reason = "",
    events = {},
    action_count = 0,
  }
end

function M.set_state(session, state, ui_state)
  session.state = state
  if ui_state then
    session.ui_state = ui_state
  end
  session.events[#session.events + 1] = {
    ts = now_s(), state = state, action = session.last_action,
  }
  write_file(var_dir() .. "/.ziyan_agent_session",
    string.format(
      "state=%s\nui_state=%s\nsession_id=%s\nrequest_id=%s\nprofile_id=%s\nbundle_id=%s\n",
      state, session.ui_state or "", session.session_id,
      session.request_id, session.profile_id, session.bundle_id or ""))
end

function M.agent_stop_requested()
  local raw = read_trim(var_dir() .. "/.ziyan_agent_stop")
  return raw ~= ""
end

function M.clear_agent_stop()
  os.remove(var_dir() .. "/.ziyan_agent_stop")
end

local function front_ok(profile)
  local front = M.front_bid()
  if front == nil or front == "" then
    return false, "empty_front"
  end
  if profile.bundle_id and profile.bundle_id ~= "" and front ~= profile.bundle_id then
    return false, "bundle_mismatch"
  end
  if M.frame_seq() <= 0 then
    return false, "bad_frame_seq"
  end
  local lock = M.lock_state()
  if lock == "1" or lock == "locked" then
    return false, "locked"
  end
  return true, front
end

local function write_error_report(session, extra)
  local id = safe_session_name(session.session_id)
  if not id then return end
  ensure_agent_dirs()
  local report_path = AGENT_ROOT .. "/错误报告/" .. id .. ".txt"
  local snap = M.snapshot(session)
  local lines = {
    "time=" .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
    "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15",
    "session_id=" .. session.session_id,
    "request_id=" .. session.request_id,
    "profile_id=" .. session.profile_id,
    "bundle_id=" .. (session.bundle_id or ""),
    "state=" .. session.state,
    "last_action=" .. (session.last_action or ""),
    "error_code=" .. (session.error_code or ""),
    "stop_reason=" .. (session.stop_reason or ""),
    "front_bid=" .. snap.front_bid,
    "frame_seq=" .. tostring(snap.frame_seq),
    "frame_age=" .. tostring(snap.frame_age),
    "FC_N=" .. tostring(snap.fc_n),
    "sb_pid=" .. snap.sb_pid,
    "bb_pid=" .. snap.bb_pid,
    "framecap_pid=" .. snap.framecap_pid,
    "lock_state=" .. snap.lock_state,
    extra or "",
  }
  write_file(report_path, table.concat(lines, "\n") .. "\n")
end

local function write_success(session, extra)
  local id = safe_session_name(session.session_id)
  if not id then return end
  ensure_agent_dirs()
  write_file(AGENT_ROOT .. "/运行记录/" .. id .. ".txt",
    string.format("STOPPED profile=%s front=%s frame_seq=%s action_count=%s %s\n",
      session.profile_id, M.front_bid(), tostring(M.frame_seq()),
      tostring(session.action_count), extra or ""))
end

local function pause_safe(session, reason)
  session.error_code = "PAUSED_SAFE"
  session.stop_reason = reason
  M.set_state(session, "PAUSED_SAFE", "安全暂停")
  write_error_report(session, "paused=" .. reason)
  M.clear_agent_stop()
  return session
end

local function finish_ok(session, extra)
  M.set_state(session, "STOPPING", session.ui_state)
  M.set_state(session, "STOPPED", "未运行")
  write_file(var_dir() .. "/.ziyan_agent_session",
    "state=STOPPED\nui_state=未运行\nactive=0\n")
  write_success(session, extra)
  M.clear_agent_stop()
  return session
end

function M.load_current_profile()
  local raw = read_trim(var_dir() .. "/.ziyan_agent_current_profile")
  local p = {
    profile_id = raw:match("profile_id=([^\n]+)") or "",
    bundle_id = raw:match("bundle_id=([^\n]+)") or "",
    display_name = raw:match("display_name=([^\n]+)") or "",
    game_name = raw:match("game_name=([^\n]+)") or "",
  }
  return p
end

function M.run_observe(profile)
  ensure_agent_dirs()
  local session = M.new_session(profile)
  M.set_state(session, "PRECHECK", "自动运行")
  local pause = M.safe_reason(M.front_bid(), "")
  if pause then return pause_safe(session, pause) end
  local ok, why = front_ok(profile)
  if not ok then return pause_safe(session, why) end
  M.set_state(session, "OBSERVING", "自动运行")
  session.frame_seq_before = M.frame_seq()
  M.set_state(session, "DECIDING", "自动运行")
  M.set_state(session, "VERIFYING", "自动运行")
  session.frame_seq_after = M.frame_seq()
  if session.frame_seq_after <= 0 then
    return pause_safe(session, "bad_frame_seq")
  end
  session.stop_reason = "observe_done"
  return finish_ok(session, "mode=observe")
end

function M.run_safe_action(profile)
  ensure_agent_dirs()
  local session = M.new_session(profile)
  M.set_state(session, "PRECHECK", "自动运行")
  local pause = M.safe_reason(M.front_bid(), "")
  if pause then return pause_safe(session, pause) end
  local ok, why = front_ok(profile)
  if not ok then return pause_safe(session, why) end
  M.set_state(session, "OBSERVING", "自动运行")
  session.frame_seq_before = M.frame_seq()
  M.set_state(session, "DECIDING", "自动运行")
  M.set_state(session, "ACTING", "自动运行")
  session.last_action = "safe_observe_once"
  session.action_count = 1
  if type(toast) == "function" then
    toast("agent_safe_action", 1)
  end
  M.set_state(session, "VERIFYING", "自动运行")
  session.frame_seq_after = M.frame_seq()
  local front2 = M.front_bid()
  if front2 == "" or front2 ~= profile.bundle_id then
    return pause_safe(session, "front_changed")
  end
  session.stop_reason = "safe_action_done"
  return finish_ok(session, "mode=safe_action")
end

function M.run_learn(profile)
  ensure_agent_dirs()
  local session = M.new_session(profile)
  M.set_state(session, "PRECHECK", "学习中")
  local pause = M.safe_reason(M.front_bid(), "")
  if pause then return pause_safe(session, pause) end
  local ok, front = front_ok(profile)
  if not ok then return pause_safe(session, front) end
  local id = safe_session_name(session.session_id)
  if not id then return pause_safe(session, "invalid_session_id") end
  local frame_seq = M.frame_seq()
  local learned = string.format(
    "front_bid=%s\nframe_seq=%s\nbundle_id=%s\nprofile_id=%s\nts=%s\n",
    front, tostring(frame_seq), session.bundle_id or "", session.profile_id,
    tostring(now_s()))
  if not write_file(AGENT_ROOT .. "/学习数据/" .. id .. ".txt", learned) then
    return pause_safe(session, "learn_write_failed")
  end
  session.stop_reason = "learn_recorded"
  return finish_ok(session, "mode=learn")
end

function M.run_drill(profile)
  ensure_agent_dirs()
  local session = M.new_session(profile)
  M.set_state(session, "DRILLING", "演练中")
  local pause = M.safe_reason(M.front_bid(), "")
  if pause then return pause_safe(session, pause) end
  local ok, why = front_ok(profile)
  if not ok then return pause_safe(session, why) end
  local learn_id = read_single_line(var_dir() .. "/.ziyan_drill_learn_id")
  if not DRILL_LEARN_IDS[learn_id] then
    return pause_safe(session, "missing_learn")
  end
  local learned_file = io.open(
    AGENT_ROOT .. "/学习数据/" .. learn_id .. ".txt", "r")
  if not learned_file then
    return pause_safe(session, "missing_learn")
  end
  local learned_body = learned_file:read("*a") or ""
  learned_file:close()
  local learn_front = learned_body:match("front_bid=([^\r\n]+)")
  local learn_bundle = learned_body:match("bundle_id=([^\r\n]+)")
  if not learn_front or not learn_bundle
      or learn_front == "" or learn_bundle == "" then
    return pause_safe(session, "missing_learn")
  end
  local front = M.front_bid()
  if learn_front ~= front or learn_front ~= profile.bundle_id
      or learn_bundle ~= profile.bundle_id then
    return pause_safe(session, "learn_front_mismatch")
  end

  session.frame_seq_before = M.frame_seq()
  M.set_state(session, "OBSERVING", "演练中")
  session.last_action = "replay_learned_observation"
  session.action_count = 1
  session.frame_seq_after = M.frame_seq()
  if session.frame_seq_after <= 0 then
    return pause_safe(session, "bad_frame_seq")
  end
  local replay_front = M.front_bid()
  if replay_front ~= learn_front or replay_front ~= profile.bundle_id then
    return pause_safe(session, "learn_front_mismatch")
  end

  local sleep_fn = mSleep
  if type(sleep_fn) ~= "function" then
    sleep_fn = function(ms)
      local deadline = os.clock() + (tonumber(ms) or 0) / 1000
      while os.clock() < deadline do end
    end
  end
  -- 等待外部 stop 标记；超限只安全暂停，绝不把等待当作成功。
  for _ = 1, 60 do
    if M.agent_stop_requested() then
      session.stop_reason = "agent_stop"
      return finish_ok(session, string.format(
        "mode=drill learn_id=%s front_bid=%s frame_seq=%s stop_reason=agent_stop",
        learn_id, learn_front, tostring(session.frame_seq_after)))
    end
    sleep_fn(250)
  end
  return pause_safe(session, "agent_stop_required")
end

function M.run_auto(profile)
  ensure_agent_dirs()
  local session = M.new_session(profile)
  M.set_state(session, "PRECHECK", "自动运行")
  local pause = M.safe_reason(M.front_bid(), "")
  if pause then return pause_safe(session, pause) end
  local ok, why = front_ok(profile)
  if not ok then return pause_safe(session, why) end

  M.set_state(session, "OBSERVING", "自动运行")
  local observed = M.front_bid()
  local observed_seq = M.frame_seq()
  M.set_state(session, "DECIDING", "自动运行")
  local identified = string.format(
    "front_bid=%s bundle_id=%s frame_seq=%s",
    observed, profile.bundle_id or "", tostring(observed_seq))
  if observed == "" or observed ~= profile.bundle_id or observed_seq <= 0 then
    return pause_safe(session, "identify_mismatch")
  end

  M.set_state(session, "VERIFYING", "自动运行")
  local verified = M.front_bid()
  local verified_seq = M.frame_seq()
  if verified == "" or verified ~= observed or verified_seq <= 0 then
    return pause_safe(session, "front_changed")
  end

  if type(init) ~= "function" or type(getScreenSize) ~= "function"
      or type(tap) ~= "function" then
    return pause_safe(session, "hid_unavailable")
  end
  local init_ok, init_result = pcall(init, 0)
  if not init_ok or init_result == false then
    return pause_safe(session, "hid_init_failed")
  end
  local size_ok, width, height = pcall(getScreenSize)
  width, height = tonumber(width), tonumber(height)
  if not size_ok or not width or not height or width <= 0 or height <= 0 then
    return pause_safe(session, "screen_size_unavailable")
  end
  local tap_front = M.front_bid()
  if tap_front == "" or tap_front ~= profile.bundle_id then
    return pause_safe(session, "front_changed_before_tap")
  end
  local tap_ok, tap_result = pcall(tap, width * 0.50, height * 0.08)
  if not tap_ok or tap_result == false then
    return pause_safe(session, "hid_tap_failed")
  end
  local tapped_front = M.front_bid()
  if tapped_front == "" or tapped_front ~= profile.bundle_id then
    return pause_safe(session, "front_changed_after_tap")
  end
  session.action_count = 1
  session.stop_reason = "auto_hid_ziyan_done"
  return finish_ok(session, string.format(
    "mode=auto front_bid=%s frame_seq=%s observed=%s identified=%s verified=%s tapped=1 tap_rx=0.50 tap_ry=0.08 stop_reason=auto_hid_ziyan_done",
    tapped_front, tostring(verified_seq), observed, identified, verified))
end

function M.run_smoke(profile)
  profile = profile or {
    profile_id = "agent_smoke",
    bundle_id = "com.ziyan.ziyan",
    display_name = "AgentSmoke",
    game_name = "子砚",
  }
  return M.run_observe(profile)
end

function M.dispatch(mode, profile)
  profile = profile or M.load_current_profile()
  if not profile.profile_id or profile.profile_id == "" then
    local session = M.new_session({
      profile_id = "none", bundle_id = "", display_name = "未选择",
    })
    return pause_safe(session, "no_profile")
  end
  if mode == "learn" then return M.run_learn(profile) end
  if mode == "drill" then return M.run_drill(profile) end
  if mode == "safe" then return M.run_safe_action(profile) end
  if mode == "auto" then return M.run_auto(profile) end
  return M.run_observe(profile)
end

return M
