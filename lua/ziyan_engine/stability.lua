--[[
  StabilityAnalyzer — SpringBoard / 脚本长跑稳定性采集（阶段7.6.2-R4）
  宿主机采集 → logs/stability/*.jsonl
  设备侧写轻量心跳到 var/.ziyan_stability_pulse（可选）
]]

local M = { name = "StabilityAnalyzer", version = "1.0.0" }

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/bin/lua5.3", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local _loop = 0
local _find_n = 0
local _tap_n = 0
local _toast_n = 0

function M.bump_loop()
  _loop = _loop + 1
end

function M.bump_find()
  _find_n = _find_n + 1
end

function M.bump_tap()
  _tap_n = _tap_n + 1
end

function M.bump_toast()
  _toast_n = _toast_n + 1
end

function M.pulse(extra)
  pcall(function()
    local path = var_dir() .. "/.ziyan_stability_pulse"
    local f = io.open(path, "w")
    if not f then return end
    f:write(string.format(
      "ts=%d loop=%d find=%d tap=%d toast=%d pid=%s extra=%s\n",
      os.time(), _loop, _find_n, _tap_n, _toast_n,
      tostring(extra and extra.pid or ""),
      tostring(extra and extra.note or "")
    ))
    f:close()
  end)
end

function M.snapshot_table()
  return {
    ts = os.time(),
    loop = _loop,
    find = _find_n,
    tap = _tap_n,
    toast = _toast_n,
  }
end

function M.install()
  _G.ZiYanStability = M
  -- 轻量挂钩：不改 tap 语义，仅计数
  -- 注意：HealthMonitor 也会 hook toast（智能抑制），两者链式兼容
  local raw_toast = _G.toast
  if type(raw_toast) == "function" and not _G.__ZIYAN_STAB_TOAST then
    _G.__ZIYAN_STAB_TOAST = true
    _G.toast = function(...)
      M.bump_toast()
      -- 如果 HealthMonitor 已 hook 了 toast，则 raw_toast 就是 HealthMonitor 的 smart_toast
      return raw_toast(...)
    end
  end
  -- 每 500 轮将计数同步到 HealthMonitor（如果已加载）
  if _G.HealthMonitor then
    _G.HealthMonitor.loop_count = _loop
  end
end

return M
