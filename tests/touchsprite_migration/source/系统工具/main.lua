
init("0", 1);
while (true) do
	local x,y = findMultiColorInRegionFuzzy( 0xbd8216, "0|1|0xbc7f14,0|2|0xd19025,0|3|0xc68318", 90,1009,  330, 1009,  333)
	if x ~= -1 then
		toast( "iOS7找到目标:"..x..","..y,1)
		touchDown(x, y)
		mSleep(100)
		touchUp(x, y)
		mSleep(1000)
	else
		x,y = findMultiColorInRegionFuzzy( 0x90643b, "0|1|0x91653b,0|2|0x92673c,0|3|0x95683c", 90, 652,  443, 652,  446)
		if x ~= -1 then
			toast("登录",1)
		else
			toast("iOS7 searching",1)
		end
	end
	mSleep(500)
end

--while (true) do
--	toast("当前设置init(2)显示位置",1)
--	mSleep(2000)
--end