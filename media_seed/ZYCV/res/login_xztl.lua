function main()
  init(1)
  while true do
    -- TSColorPicker: dump init(1) 正向横屏（Home右）USB 2208x1242
    local x, y = findMultiColorInRegionFuzzy( 0xd20107, "1|0|0xd20001,2|0|0xc50000,3|0|0xc70e09", 90, 2112, 562, 2116, 566)
    local time = NetTime()
    toast( "时间:" .. time .. " 点:" .. x .. "," .. y ,1500 )

    if x ~= -1 then mSleep(400)  tap(x, y) end

    mSleep(1200)
    -- 防 SB jetsam：全屏 OCR 降频（配合引擎 12s 缓存）
    _G.__ziyan_ocr_round = (_G.__ziyan_ocr_round or 0) + 1
    if _G.__ziyan_ocr_round % 10 == 0 then
      local text = ""
      local okg, t = pcall(getText, 0, 0, -1, -1)
      if okg and t then text = t end
      if text ~= "" then
        toast("OCR:" .. text, 1500)
      else
        toast("OCR无结果", 1000)
      end
      mSleep(800)
    end
  end
end
