--[[ Zy.Verify — 结果验证模块
  硬规则：禁止虚假 PASS。
  - requestSuccess / success(label)：仅「请求记一次成功意图」，verified=false, pass=false
  - verifiedSuccess / act：须有可核对证据后才 pass=true
]]
local C = require("modules._ctx")
local M = { name = "Verify", version = "1.1.0" }

local function defined(n) return type(_G[n]) == "function" end

local function var_dir()
  local Zy = _G.Zy
  if Zy and Zy.File and type(Zy.File.varDir) == "function" then
    local ok, d = pcall(Zy.File.varDir)
    if ok and type(d) == "string" and #d > 0 then return d end
  end
  return _G.ZIYAN_VAR or (io.open("/var/jb/usr/lib/ziyan/var", "r") and "/var/jb/usr/lib/ziyan/var" or "/usr/lib/ziyan/var")
end

local function append_jsonl(name, fields)
  pcall(function()
    local f = io.open(var_dir() .. "/" .. name, "a")
    if not f then return end
    local parts = {}
    for k, v in pairs(fields) do
      local t = type(v)
      if t == "number" then
        parts[#parts + 1] = string.format('"%s":%s', k, tostring(v))
      elseif t == "boolean" then
        parts[#parts + 1] = string.format('"%s":%s', k, v and "true" or "false")
      else
        parts[#parts + 1] = string.format('"%s":"%s"', k, tostring(v or ""):gsub('"', "'"):gsub("\n", " "))
      end
    end
    f:write("{" .. table.concat(parts, ",") .. "}\n")
    f:close()
  end)
end

function M.fingerprint(bid)
  pcall(C.require_pipeline, "verify")
  bid = bid or C.bid
  if defined("verifyFingerprint") then return verifyFingerprint(bid) end
  return { phase = "?", bid = tostring(bid or "") }
end

--- 请求成功（兼容脚本 Zy.Verify.success）：不宣称 PASS
function M.requestSuccess(label)
  local rec = {
    kind = "request",
    verified = false,
    pass = false,
    label = tostring(label or ""),
    ts = os.time(),
    status = "requested_not_verified",
  }
  M._last_request = rec
  M._last_result = rec
  append_jsonl(".ziyan_verify_request.jsonl", rec)
  -- 8-161-61：light 禁 Verify toast（命中路径多一次 toast 叠节流，节奏跟不上触动）
  if defined("toast") and not _G.ZIYAN_LIGHT then
    pcall(toast, "Verify请求(未验证):" .. tostring(label or ""), 800)
  end
  -- 返回 false：明确不是 verified PASS（脚本可忽略返回值）
  return false, rec, "requested_not_verified"
end

--- 兼容 ios7/ios8p：Zy.Verify.success(msg) → 仅 request，禁止当 PASS
function M.success(label)
  return M.requestSuccess(label)
end

--- 真实验证成功：必须带证据，否则降级为 request
-- evidence: { ok=true } | { phase_change=true } | { fingerprint=table } | { via="act", detail=... }
function M.verifiedSuccess(label, evidence)
  evidence = type(evidence) == "table" and evidence or {}
  local has = evidence.ok == true
      or evidence.phase_change == true
      or evidence.verified == true
      or type(evidence.fingerprint) == "table"
      or type(evidence.detail) == "string" and #evidence.detail > 0
  if not has then
    return M.requestSuccess(label)
  end
  local rec = {
    kind = "verified",
    verified = true,
    pass = true,
    label = tostring(label or ""),
    ts = os.time(),
    status = "verified_success",
    via = tostring(evidence.via or "verifiedSuccess"),
    detail = tostring(evidence.detail or evidence.reason or ""),
  }
  M._last_verified = rec
  M._last_result = rec
  append_jsonl(".ziyan_verify_ok.jsonl", rec)
  return true, rec, "verified_success"
end

function M.act(label, act_fn, wait_ms)
  pcall(C.require_pipeline, "verify")
  local bid = C.bid or _G.__ZIYAN_LAST_BID
  if defined("verifyAct") then
    local ok, after, why = verifyAct(bid, label, act_fn, wait_ms)
    if ok then
      M.verifiedSuccess(label, { ok = true, via = "verifyAct", detail = tostring(why or "") })
    else
      M.requestSuccess(tostring(label or "") .. ":" .. tostring(why or "fail"))
    end
    return ok, after, why
  end
  local before = M.fingerprint(bid)
  if type(act_fn) == "function" then pcall(act_fn) end
  if defined("mSleep") then mSleep(wait_ms or 1200) end
  local after = M.fingerprint(bid)
  local ok = before.phase ~= after.phase and after.phase ~= "?"
  if ok then
    M.verifiedSuccess(label, { phase_change = true, via = "phase", detail = tostring(before.phase) .. "->" .. tostring(after.phase) })
  else
    M.requestSuccess(tostring(label or "") .. ":no_phase_change")
  end
  return ok, after, ok and "phase_change" or "no_change"
end

function M.failReport(opts)
  opts = opts or {}
  opts.bid = opts.bid or C.bid
  local structured = {
    bid = opts.bid,
    phase = opts.phase,
    reason = opts.reason,
    module = opts.module,
    fix = opts.fix,
    tag = opts.tag,
    label = opts.label,
    ts = os.time(),
    pass = false,
    verified = false,
  }
  M._last_fail = structured
  append_jsonl(".ziyan_verify_fail.jsonl", {
    ts = structured.ts,
    bid = structured.bid,
    phase = structured.phase,
    reason = structured.reason,
    module = structured.module,
    tag = structured.tag,
  })
  if defined("verifyFailReport") then return verifyFailReport(opts) end
  return structured
end

function M.lastFail()
  return M._last_fail
end

function M.lastResult()
  return M._last_result
end

function M.lastRequest()
  return M._last_request
end

function M.lastVerified()
  return M._last_verified
end

--- 是否曾宣称 verified PASS（不含 request）
function M.isVerifiedPass()
  local r = M._last_verified
  return type(r) == "table" and r.pass == true and r.verified == true
end

return M
