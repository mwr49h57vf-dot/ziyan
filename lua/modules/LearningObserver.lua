--[[
  LearningObserver — TouchSprite 学习观察日志（阶段7.6.2-R3.3）
  ------------------------------------------------------------
  仅用于第一类设备 192.168.31.149 / .171 的只读采集与归档。
  禁止：部署子砚、Hook TS、改脚本、注入、把观察结果写成子砚 PASS。

  日志目录（宿主机）：
    /Users/mac/Desktop/ZiYan_副本/logs/touchsprite_learning/

  记录字段（JSONL / 文本快照）：
    time, device, script, function, args, returns,
    coords, screen_size, orientation, run_state, error, lifecycle
]]

local M = {
  name = "LearningObserver",
  version = "1.0.0",
  role = "ts_observe_only",
  devices = { "192.168.31.149", "192.168.31.171" },
  log_dir = "/Users/mac/Desktop/ZiYan_副本/logs/touchsprite_learning",
  forbidden = {
    "deploy_ziyan",
    "modify_ts",
    "hook_inject",
    "use_as_ziyan_pass",
  },
}

--- 设计：宿主机周期拉取 TS 公开日志，不驻留设备进程
M.collect_sources = {
  "/var/mobile/Media/TouchSprite/log/ts.log",
  "/var/mobile/Media/TouchSprite/log/err.log",
  "/var/mobile/Media/TouchSprite/config/config.plist",
  "/var/mobile/Media/TouchSprite/config/run.cfg",
  "/var/mobile/Media/TouchSprite/config/screen.cfg",
}

M.focus = {
  "init / screen size / orientation",
  "findColor / findMultiColor / findImage returns",
  "tap / touchDown lifecycle",
  "volume / float window vs screen",
  "long-run stability (TSDaemon uptime, restart cadence)",
}

function M.schema()
  return {
    time = "ISO8601 or device local",
    device = "IP",
    script = "path under Media/TouchSprite/lua",
    ["function"] = "name if parseable from log",
    args = "string",
    returns = "string",
    coords = "x,y if present",
    screen_size = "WxH",
    orientation = "init 0/1/2 if known",
    run_state = "start|end|error|running",
    error = "message",
    lifecycle = "daemon_pid / uptime note",
  }
end

function M.assert_observe_only(ip)
  for _, d in ipairs(M.devices) do
    if d == ip then
      return true
    end
  end
  return false, "not a TouchSprite learning device"
end

return M
