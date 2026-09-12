-- Non-Agent business sample distilled from:
--   E48/系统工具/main.lua: touchDown/touchUp/mSleep loop
--   E48/龙界争霸/LJZBQS.lua: getColor/findColor polling
-- No credentials, external business, payment, or account data.

local Zy = require("modules.init")
local Script = Zy.Script
local App = Zy.App
local Device = Zy.Device
local Image = Zy.Image
local Screen = Zy.Screen
local Touch = Zy.Touch
local Log = Zy.Log

local BID = os.getenv("ZIYAN_SAMPLE_BID") or "com.xztl.ios"
local DESIGN_W = tonumber(os.getenv("ZIYAN_SAMPLE_W")) or 1136
local DESIGN_H = tonumber(os.getenv("ZIYAN_SAMPLE_H")) or 640
local RUN_LIMIT = tonumber(os.getenv("ZIYAN_SAMPLE_LOOPS")) or 3
local SAMPLE_TAG = "e48_non_agent_business"

local function write_result(status, detail)
  local root = os.getenv("ZIYAN_SAMPLE_RESULT") or "/tmp/ziyan_e48_sample_result.txt"
  local f = io.open(root, "w")
  if f then
    f:write("status=", tostring(status), "\n")
    f:write("detail=", tostring(detail or ""), "\n")
    f:write("sample=", SAMPLE_TAG, "\n")
    f:close()
  end
end

local function wait_for_color(timeout_ms)
  local ok, x, y = Image.findUntil(
    0xE8C070, "", 90, 0, 0, DESIGN_W - 1, DESIGN_H - 1,
    timeout_ms, 120
  )
  return ok, x, y
end

local function cleanup()
  pcall(function() Screen.keep(false) end)
  pcall(function() App.close(BID) end)
  pcall(function() Log.write("sample cleanup complete") end)
end

local function main()
  local ok, err = xpcall(function()
    Script.begin({
      bid = BID,
      design_w = DESIGN_W,
      design_h = DESIGN_H,
      orient = 1,
    })
    Log.write("sample start tag=" .. SAMPLE_TAG)

    local profile = Device.profile and Device.profile() or {}
    Log.write("device profile=" .. tostring(profile.model or "unknown"))

    local front_before = App.front()
    Log.write("foreground before=" .. tostring(front_before))

    -- Foreground/background lifecycle is exercised through the existing app API.
    if App.isForeground(BID) ~= true then
      App.activate(BID, 1200)
    end
    local front_active = App.front()
    Log.write("foreground active=" .. tostring(front_active))

    Screen.keep(true)
    local color = Image.colorAtDesign(math.floor(DESIGN_W * 0.5), math.floor(DESIGN_H * 0.5))
    Log.write(string.format("sample color=0x%06X", tonumber(color) or 0))

    local sx, sy = DESIGN_W * 0.40, DESIGN_H * 0.78
    local ex, ey = DESIGN_W * 0.60, DESIGN_H * 0.64
    Touch.fingerDown(1, sx, sy)
    Touch.fingerMove(1, ex, ey)
    Touch.fingerUp(1, ex, ey)
    Touch.tapDesign(math.floor(DESIGN_W * 0.5), math.floor(DESIGN_H * 0.72), 70)

    local state = "searching"
    for i = 1, RUN_LIMIT do
      Log.write("state=" .. state .. " loop=" .. i)
      local hit, x, y = wait_for_color(360)
      if hit then
        state = "hit"
        Log.write(string.format("find color hit x=%d y=%d", x, y))
        Touch.tapHit(x, y, 70)
        break
      end
      state = "timeout"
      Log.write("find color timeout loop=" .. i)
    end

    -- Existing image capability is called, but a missing asset is a valid miss.
    local image_path = os.getenv("ZIYAN_SAMPLE_IMAGE") or ""
    if image_path ~= "" then
      local ix, iy = Image.find(image_path, 0.90)
      Log.write(string.format("find image x=%s y=%s", tostring(ix), tostring(iy)))
    else
      Log.write("find image skipped: no approved runtime asset")
    end

    local snap = Screen.snapshot(SAMPLE_TAG)
    Log.write("snapshot=" .. tostring(snap))
    write_result("completed", "start_stop_click_swipe_color_wait_loop_state_fg_bg_snapshot")
  end, debug.traceback)
  cleanup()
  if not ok then
    write_result("error_cleaned", err)
    Log.write("sample error=" .. tostring(err))
    error(err, 0)
  end
end

main()
