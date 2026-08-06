function main()
  init(1)
  local round = 0
  local OUT = (rawget(_G, "ZIYAN_VAR") or "/var/jb/usr/lib/ziyan/var")
      .. "/.ziyan_login_usb_round.txt"
  while true do
    round = round + 1
    local rf = io.open(OUT, "w")
    if rf then
      rf:write(string.format("round=%d\n", round))
      rf:close()
    end
    local x, y = findMultiColorInRegionFuzzy(
      0xb9271b, "1|0|0xb9271b,2|0|0xb9271b,3|0|0xb9271b", 90, 2111, 549, 2114, 549)
    local okt, time = pcall(NetTime, 3)
    if not okt or not time or time == "" then
      time = "获取失败"
    end
    toast("时间:" .. tostring(time) .. " 点:" .. tostring(x) .. "," .. tostring(y), 1500)

    if x ~= -1 then
      mSleep(400)
      pcall(tap, x, y)
    end

    mSleep(1200)
    -- 防 SB jetsam：全屏 OCR 每 10 轮一次
    if round % 10 == 0 then
      local okg, text = pcall(getText, 0, 0, -1, -1)
      if okg and text and text ~= "" then
        toast("OCR:" .. tostring(text), 1500)
      else
        toast("OCR无结果", 1000)
      end
      mSleep(800)
    end
  end
end
