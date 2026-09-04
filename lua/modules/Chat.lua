--[[ Zy.Chat — 无账号/支付依赖的通用聊天交互模块
  负责当前前台聊天界面的输入、发送、清空、复制和消息状态记录。
  具体 UI 坐标由调用方通过 ScreenTransform/AI 生成，不写死物理坐标。
]]
local M = { name = "Chat", version = "1.0.0" }
local state = { active = false, id = nil, messages = {}, last = nil, status = "idle" }

local function now() return os.time() end

function M.openFixture(opts)
  opts = opts or {}
  local Zy = assert(_G.Zy, "Zy required")
  local var = Zy.File and Zy.File.varDir and Zy.File.varDir()
  if type(var) ~= "string" or var == "" then
    return false, "var_unavailable"
  end
  Zy.File.remove(var .. "/.ziyan_chat_fixture_ready")
  local ok = Zy.File.write(var .. "/.ziyan_ui_cmd", "open_chat_fixture\n")
  if ok == false then return false, "fixture_command_failed" end
  if Zy.Timer and Zy.Timer.waitUntil and Zy.File.read then
    return Zy.Timer.waitUntil(function()
      return Zy.File.read(var .. "/.ziyan_chat_fixture_ready"):find("ready=1", 1, true) ~= nil
    end, tonumber(opts.timeout_ms) or 8000, tonumber(opts.interval_ms) or 250)
  end
  return false, "fixture_wait_unavailable"
end

local function media_templates()
  return "/private/var/mobile/Media/ZiYan/templates"
end

-- 阶段目录用通用名，禁止 Bundle 文件名。发送按钮 → chat_send/send.png
local TEMPLATE_ALIAS = {
  ["发送"] = { phase = "chat_send", file = "send.png" },
  ["send"] = { phase = "chat_send", file = "send.png" },
  ["输入"] = { phase = "chat_send", file = "input.png" },
  ["世界"] = { phase = "chat_send", file = "world.png" },
}

local function sanitize_file(s)
  local out = tostring(s or ""):gsub("[^%w%._%-]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if out == "" then out = "echo" end
  return out:sub(1, 48) .. ".png"
end

local function image_fuzzy(opts)
  local fuzzy = tonumber(opts and (opts.fuzzy or opts.sim)) or 80
  if fuzzy > 0 and fuzzy <= 1 then fuzzy = math.floor(fuzzy * 100 + 0.5) end
  return fuzzy
end

local function resolve_template(name, opts)
  opts = opts or {}
  local path = opts.image or opts.template
  if type(path) == "string" and path ~= "" then return path end
  local alias = TEMPLATE_ALIAS[tostring(name or "")]
  local phase = opts.phase or (alias and alias.phase) or "chat_echo"
  local file = alias and alias.file or sanitize_file(name)
  return media_templates() .. "/" .. phase .. "/" .. file
end

local function template_exists(path)
  if type(path) ~= "string" or path == "" then return false end
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

-- OCR 未命中或报错后才找图，不替换 OCR。模板在盘时跳过会挂死的 OCR。
local function find_by_image(name, opts)
  local Zy = _G.Zy
  if not Zy or not Zy.Image or type(Zy.Image.find) ~= "function" then
    return false, -1, -1, "image_unavailable"
  end
  opts = opts or {}
  if opts.matcher and type(Zy.Image.match) == "function" then
    local hit, x, y = Zy.Image.match(opts.matcher)
    if hit and tonumber(x) and x >= 0 then return true, x, y, "image_matcher" end
  end
  local path = resolve_template(name, opts)
  local x, y = Zy.Image.find(path, image_fuzzy(opts))
  x, y = tonumber(x), tonumber(y)
  if x and y and x >= 0 and y >= 0 then return true, x, y, "image" end
  return false, -1, -1, "image_miss"
end

local function find_label(label, opts)
  opts = opts or {}
  local path = resolve_template(label, opts)
  -- 模板存在时优先找图；模板缺失时必须保留 OCR fallback，即使调用方
  -- 为避免 sidecar 阻塞传入 skip_ocr=true。
  local skip_ocr = template_exists(path)
  if not skip_ocr then
    local Zy = _G.Zy
    if Zy and Zy.OCR and type(Zy.OCR.find) == "function" then
      local ok, x, y = pcall(Zy.OCR.find, label)
      x, y = tonumber(x), tonumber(y)
      if ok and x and y and x >= 0 and y >= 0 then
        return true, x, y, "ocr"
      end
    end
  end
  return find_by_image(label, opts)
end

local function find_and_tap(labels, opts)
  local Zy = _G.Zy
  if not Zy or not Zy.Touch or type(Zy.Touch.tapHit) ~= "function" then
    return false, "vision_unavailable"
  end
  for _, label in ipairs(labels or {}) do
    local hit, x, y, via = find_label(label, opts)
    if hit then
      -- Image.find returns the template's top-left corner. The send template
      -- is 89x67, so tap its center to avoid the nearby UI edge.
      local path = resolve_template(label, opts)
      if path:match("/chat_send/send%.png$") then
        x, y = x + 44, y + 33
      end
      local ok = Zy.Touch.tapHit(x, y)
      return ok ~= false, ok and (via .. ":" .. label) or "tap_failed"
    end
  end
  return false, "label_not_found"
end

function M.begin(opts)
  opts = opts or {}
  state = { active = true, id = tostring(opts.id or ("chat_" .. now())), messages = {}, last = nil, status = "ready" }
  return true, state.id
end

function M.endSession()
  state.active = false
  state.status = "stopped"
  return true
end

function M.clear()
  state.messages = {}
  state.last = nil
  state.status = "cleared"
  local Zy = _G.Zy
  if Zy and Zy.Input and Zy.Input.clear then pcall(Zy.Input.clear) end
  return true
end

local function sleep_ms(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then return end
  if type(mSleep) == "function" then mSleep(ms) end
end

-- 可玩聊天回合：不用 Input.text 当发送成功，不用夹具。
-- 输入优先剪贴板+粘贴或 tap_sequence；发送走找图中心；账号/验证码/支付不在本函数。
function M.playTurn(text, opts)
  opts = opts or {}
  text = tostring(text or "")
  if text == "" then return false, "empty_message" end
  if not state.active then M.begin({}) end
  local Zy = assert(_G.Zy, "Zy required")
  if not Zy.Touch or type(Zy.Touch.tapRatio) ~= "function" then
    return false, "touch_unavailable"
  end

  local function tap_ratio(r)
    if type(r) ~= "table" then return false end
    local x, y = tonumber(r.x or r[1]), tonumber(r.y or r[2])
    if not x or not y then return false end
    return Zy.Touch.tapRatio(x, y) ~= false
  end

  if opts.channel_labels then
    local ok_ch, ch_reason = find_and_tap(opts.channel_labels, opts)
    if not ok_ch then
      state.status = "channel_miss"
      return false, ch_reason or "channel_not_found"
    end
    sleep_ms(opts.channel_wait_ms or 250)
  elseif opts.channel_ratio then
    if not tap_ratio(opts.channel_ratio) then
      state.status = "channel_tap_failed"
      return false, "channel_tap_failed"
    end
    sleep_ms(opts.channel_wait_ms or 250)
  end

  if opts.focus_ratio then
    if not tap_ratio(opts.focus_ratio) then
      state.status = "focus_failed"
      return false, "focus_tap_failed"
    end
    sleep_ms(opts.focus_wait_ms or 200)
  elseif opts.focus_labels then
    local focused, focus_reason = find_and_tap(opts.focus_labels, opts)
    if not focused then
      state.status = "focus_failed"
      return false, focus_reason
    end
    sleep_ms(opts.focus_wait_ms or 200)
  end

  local typed = false
  local type_via = "none"
  if type(opts.tap_sequence) == "table" and #opts.tap_sequence > 0 then
    typed = true
    for _, r in ipairs(opts.tap_sequence) do
      if not tap_ratio(r) then typed = false; break end
      sleep_ms(opts.tap_char_ms or 80)
    end
    type_via = typed and "tap_sequence" or "tap_sequence_failed"
  else
    if Zy.Clipboard and type(Zy.Clipboard.set) == "function" then
      pcall(Zy.Clipboard.set, text)
    end
    if opts.paste_labels then
      if opts.paste_long_press ~= false and type(Zy.Touch.longPressRatio) == "function" then
        local fr = opts.focus_ratio or { x = 0.36, y = 0.91 }
        pcall(Zy.Touch.longPressRatio, tonumber(fr.x) or 0.36, tonumber(fr.y) or 0.91, opts.paste_hold or 20)
        sleep_ms(180)
      end
      local pasted, paste_reason = find_and_tap(opts.paste_labels, opts)
      typed = pasted and true or false
      type_via = typed and "paste_label" or (paste_reason or "paste_miss")
    elseif Zy.Clipboard and type(Zy.Clipboard.pasteToFocus) == "function" then
      local ok_paste = Zy.Clipboard.pasteToFocus()
      typed = ok_paste ~= false
      type_via = typed and "paste_to_focus" or "paste_to_focus_failed"
    end
  end
  if not typed then
    state.status = "type_failed"
    return false, "type_failed:" .. tostring(type_via)
  end

  -- 双击发送：先收键盘，再点发送模板中心。Chat.send=true 不算成功。
  if opts.dismiss_ratio then
    tap_ratio(opts.dismiss_ratio)
    sleep_ms(opts.dismiss_wait_ms or 200)
  end
  if opts.send_ratio then
    if not tap_ratio(opts.send_ratio) then
      state.status = "send_failed"
      return false, "send_tap_failed"
    end
  elseif opts.send_labels then
    local sent, send_reason = find_and_tap(opts.send_labels, opts)
    if not sent then
      state.status = "send_failed"
      return false, send_reason
    end
    sleep_ms(opts.send_wait_ms or 250)
    -- 第二下：键盘收起后再点发送中心
    local sent2 = find_and_tap(opts.send_labels, opts)
    if sent2 == false then
      state.status = "send_second_miss"
    end
  else
    state.status = "send_missing"
    return false, "send_target_required"
  end

  local msg = { role = opts.role or "user", text = text, ts = now(), sent = true, via = type_via }
  state.messages[#state.messages + 1] = msg
  state.last = msg
  state.status = "sent"

  local verified, verify_reason = false, "not_checked"
  if opts.verify ~= false then
    verified, verify_reason = M.verifyLast({
      text = text, skip_ocr = true, phase = opts.echo_phase or "chat_echo",
      image = opts.echo_image, fuzzy = opts.fuzzy,
    })
  end

  if opts.close_ratio then
    sleep_ms(opts.close_wait_ms or 200)
    tap_ratio(opts.close_ratio)
  elseif opts.close_labels then
    find_and_tap(opts.close_labels, opts)
  end

  if opts.verify ~= false and not verified then
    state.status = "sent_unverified"
    return false, "result_not_found:" .. tostring(verify_reason)
  end
  return true, msg
end

function M.send(text, opts)
  opts = opts or {}
  text = tostring(text or "")
  if text == "" then return false, "empty_message" end
  if not state.active then M.begin({}) end
  local Zy = assert(_G.Zy, "Zy required")
  if not Zy.Input or type(Zy.Input.text) ~= "function" then return false, "input_unavailable" end
  if opts.focus_ratio and Zy.Touch and Zy.Touch.tapRatio then
    local r = opts.focus_ratio
    local focused = Zy.Touch.tapRatio(r.x, r.y)
    if focused == false then state.status = "focus_failed"; return false, "focus_tap_failed" end
  elseif opts.focus_labels then
    local focused, focus_reason = find_and_tap(opts.focus_labels, opts)
    if not focused then state.status = "focus_failed"; return false, focus_reason end
  end
  local input_ok, input_reason = Zy.Input.text(text, opts)
  if not input_ok then state.status = "input_failed"; return false, input_reason end
  if opts.send_ratio and Zy.Touch and Zy.Touch.tapRatio then
    local r = opts.send_ratio
    local tap_ok = Zy.Touch.tapRatio(r.x, r.y)
    if tap_ok == false then state.status = "send_failed"; return false, "send_tap_failed" end
  elseif opts.send_labels then
    local sent, send_reason = find_and_tap(opts.send_labels, opts)
    if not sent then state.status = "send_failed"; return false, send_reason end
  end
  local msg = { role = opts.role or "user", text = text, ts = now(), sent = true }
  state.messages[#state.messages + 1] = msg
  state.last = msg
  state.status = "sent"
  return true, msg
end

function M.receive(text, opts)
  opts = opts or {}
  local msg = { role = opts.role or "assistant", text = tostring(text or ""), ts = now(), sent = false }
  state.messages[#state.messages + 1] = msg
  state.last = msg
  state.status = "received"
  return true, msg
end

function M.copyLast(opts)
  opts = opts or {}
  if not state.last then return false, "no_message" end
  local Zy = _G.Zy
  if not Zy or not Zy.Clipboard then return false, "clipboard_unavailable" end
  if opts.action_labels then
    local tapped, reason = find_and_tap(opts.action_labels)
    if not tapped then return false, reason end
    state.status = "copied"
    return true, state.last.text
  end
  local ok = Zy.Clipboard.set(state.last.text)
  state.status = ok and "copied" or "copy_failed"
  return ok and true or false, state.last.text
end

function M.pasteLast(opts)
  opts = opts or {}
  if not state.last then return false, "no_message" end
  local Zy = _G.Zy
  if not Zy or not Zy.Clipboard then return false, "clipboard_unavailable" end
  if opts.action_labels then
    local tapped, reason = find_and_tap(opts.action_labels)
    if not tapped then return false, reason end
    state.status = "pasted"
    return true, "action"
  end
  if opts.focus_ratio and Zy.Touch and Zy.Touch.tapRatio then
    local r = opts.focus_ratio
    local focused = Zy.Touch.tapRatio(r.x, r.y)
    if focused == false then state.status = "paste_focus_failed"; return false, "focus_tap_failed" end
  elseif opts.focus_labels then
    local focused, focus_reason = find_and_tap(opts.focus_labels)
    if not focused then state.status = "paste_focus_failed"; return false, focus_reason end
  end
  local ok, reason = Zy.Clipboard.pasteToFocus()
  state.status = ok and "pasted" or "paste_failed"
  return ok and true or false, reason
end

function M.verifyLast(opts)
  opts = opts or {}
  if not state.last then return false, "no_message" end
  local expected = tostring(opts.text or state.last.text or "")
  if expected == "" then return false, "empty_expected" end
  local Zy = _G.Zy
  if opts.observed_text then
    local ok = tostring(opts.observed_text):find(expected, 1, true) ~= nil
    state.status = ok and "verified" or "verify_failed"
    return ok, ok and "observed_text" or "text_mismatch"
  end
  local hit, _, _, via = find_label(expected, {
    phase = opts.phase or "chat_echo",
    image = opts.image or opts.template,
    matcher = opts.matcher,
    fuzzy = opts.fuzzy or opts.sim,
    skip_ocr = opts.skip_ocr,
  })
  state.status = hit and "verified" or "verify_failed"
  return hit, hit and via or "result_not_found"
end

function M.messages()
  local out = {}
  for i, msg in ipairs(state.messages) do out[i] = msg end
  return out
end

function M.state()
  return { active = state.active, id = state.id, status = state.status, count = #state.messages, last = state.last }
end

return M
