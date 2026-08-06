--[[
  touch_mapping_test.lua — 阶段7.6.2-R3.1 角点触控映射验证
  测试：左上 / 右上 / 左下 / 右下 / 中心
  写入：var/.ziyan_coord_diag 、var/.ziyan_tap_proof
  禁止改 ios7.lua / ios8p.lua；本文件为独立诊断脚本。
]]

local function sleep_ms(ms)
  ms = tonumber(ms) or 200
  if type(mSleep) == "function" then
    mSleep(ms)
  else
    local t = os.time() + math.max(1, math.floor(ms / 1000))
    while os.time() < t do end
  end
end

init(1)
local w, h = 1136, 640
if type(getScreenSize) == "function" then
  local a, b = getScreenSize()
  if a and b and a > 0 then w, h = a, b end
end
if Zy and Zy.Screen and Zy.Screen.size then
  local ok, a, b = pcall(Zy.Screen.size)
  if ok and a and b then w, h = a, b end
end

local corners = {
  { 10, 10, "TL" },
  { w - 11, 10, "TR" },
  { 10, h - 11, "BL" },
  { w - 11, h - 11, "BR" },
  { math.floor(w / 2), math.floor(h / 2), "C" },
}

toast(string.format("mapping test %dx%d", w, h), 1500)
sleep_ms(800)

local results = {}
for _, c in ipairs(corners) do
  local x, y, name = c[1], c[2], c[3]
  local ok = tap(x, y)
  sleep_ms(350)
  local err = "?"
  if ZiYanCoordDiag and ZiYanCoordDiag.write_tap then
    err = select(1, ZiYanCoordDiag.write_tap(x, y, 1)) or "?"
  end
  results[#results + 1] = string.format("%s(%d,%d) ok=%s err=%s", name, x, y, tostring(ok), tostring(err))
  toast(results[#results], 900)
  sleep_ms(400)
end

local summary = table.concat(results, " | ")
toast("done " .. summary, 2500)
print("TOUCH_MAPPING_TEST " .. summary)
