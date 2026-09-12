init("0", 1);
require("TSLib")
local ts = require("ts")
unlockDevice()
function w_写入配置信息(mb,lx)-----删完后在写入
	ts.config.open("/User/Media/TouchSprite/res/System.plist")
	ts.config.delete(mb)---删除命令
	ts.config.save(mb,lx)---写入命令
	ts.config.close(true)
	mb,lx = nil,nil
end
function r_读取配置信息(sj)
	ts.config.open("/User/Media/TouchSprite/res/System.plist")
	local coin = ts.config.get(sj)
	ts.config.close(true)
	sj = nil
	return coin
end
function s_上传()
	local status=ts.ftp.connect("en530255688.gotoftp11.com","en530255688","3186969aa")
	--status=ts.ftp.connect("luxinwen3.gotoftp2.com","luxinwen3","5201314aa")
	if status then toast("已连接服务器",1) else toast("未连接服务器",1) status=nil lua_exit() return end
	mSleep(2000)
	ts.ftp.mkdir("XZTL")  
--	local WsnJian1="/User/Media/TouchSprite/lua/XZKW.lua"
	local WsnJian2="/User/Media/TouchSprite/lua/XZHS.lua"
	local WsnJian3="/User/Media/TouchSprite/lua/XZJH.lua"
	local WsnJian4="/User/Media/TouchSprite/lua/XZQS.lua"
	local WsnJian5="/User/Media/TouchSprite/lua/XZUI.lua"
	local xh
	for xh= 1, 4 do
		if xh==1 then
			ts.ftp.delete("/XZTL/XZHS.lua")
		elseif xh==2 then
			ts.ftp.delete("/XZTL/XZJH.lua")
		elseif xh==3 then
			ts.ftp.delete("/XZTL/XZQS.lua")
		elseif xh==4 then
			ts.ftp.delete("/XZTL/XZUI.lua")	
		end
		mSleep(50) 
	end
	for xh= 1, 4 do
		if xh==1 then
			ts.ftp.upload(WsnJian2,"/XZTL/XZHS.lua")
		elseif xh==2 then
			ts.ftp.upload(WsnJian3,"/XZTL/XZJH.lua")
		elseif xh==3 then
			ts.ftp.upload(WsnJian4,"/XZTL/XZQS.lua")
		elseif xh==4 then
			ts.ftp.upload(WsnJian5,"/XZTL/XZUI.lua")
		end
		mSleep(50) toast("文件"..xh.."已成功上传",1)
	end
	mSleep(2000)
	WsnJian1,WsnJian2,WsnJian3,WsnJian4,WsnJian5,xh=nil,nil,nil,nil,nil,nil
	mSleep(1000)
	toast("文件上传结束......",1)
	mSleep(1000)
	ts.ftp.close()
end	
function b_版本号比较()
	local js=1
	local WwIp
	while (true) do
		setWifiEnable(true) 
		mSleep(3000) WwIp=getNetIP()
		if WwIp and WwIp ~= ""  then
			toast("网络已正常连接.....",1)
			mSleep(3000) js=nil
			break
		else
			js=js+1
			if js>=21 then
				setWifiEnable(false) 
				js=1
			end
			mSleep(3000) toast("正在恢复网络连接,长久不连接请检查网络",1)
		end
	end
	WwIp=nil
	-- 连接 FTP 服务器
	local status=ts.ftp.connect("en530255688.gotoftp11.com","en530255688","3186969aa")
	local xh,WsnJian
	for xh= 1, 15 do
		if status then
			WsnJian = "/private/var/mobile/Media/TouchSprite/res/BBH.lua"--程序版本
			delFile(WsnJian)
			ts.ftp.download(WsnJian, "/XZTL/BBH.lua")  -- 下载当前版本号
			mSleep(1000) ts.ftp.close()
			local LsBbHnR = r_读取配置信息("历史版本号")
			local XzBbHnR = readFileString(WsnJian)  -- 读文件返回字符串
			if LsBbHnR ~= XzBbHnR then
				toast("开始更新版本....", 1)
				--w_写入配置信息("历史版本号",XzBbHnR)
				mSleep(500)
				x_下载(true)  -- 文件更新
				mSleep(2000) setWifiEnable(false) --关闭网络
				break
			else
				toast("当前版本不需要更新", 1)
				break
			end
		else
			mSleep(1000) toast("尝试重新访问FTP服务器......", 1)
			status=ts.ftp.connect("en530255688.gotoftp11.com","en530255688","3186969aa")
			mSleep(1000) 
		end
	end
	xh, status, WsnJian, LsBbHnR, XzBbHnR = nil, nil, nil, nil, nil
end
function x_下载(WlDk)
	local status
	while (true) do
		status=ts.ftp.connect("en530255688.gotoftp11.com","en530255688","3186969aa")
		if status then 
			toast("已连接",1) 
			mSleep(2000) break
		else 
			mSleep(3000) 
			toast("尝试重新访问FTP服务器......",1) 
		end
	end
	status=nil 
	mSleep(2000)
	local WsnJian1="/User/Media/TouchSprite/lua/XZHS.lua"
	local WsnJian2="/User/Media/TouchSprite/lua/XZJH.lua"
	local WsnJian3="/User/Media/TouchSprite/lua/XZQS.lua"
	local WsnJian4="/User/Media/TouchSprite/lua/XZUI.lua"
--	local WsnJian5="/User/Media/TouchSprite/lua/XZTLJH.lua"
	local JieTi = 1
	while (true) do
		if JieTi == 1 then
			local xh
			for xh= 1, 6 do
				if xh==1 then
					ts.ftp.download(WsnJian1,"/XZTL/XZHS.lua")
				elseif xh==2 then
					ts.ftp.download(WsnJian2,"/XZTL/XZJH.lua")
				elseif xh==3 then
					ts.ftp.download(WsnJian3,"/XZTL/XZQS.lua")
				elseif xh==4 then
					ts.ftp.download(WsnJian4,"/XZTL/XZUI.lua")
--				elseif xh==5 then
--					ts.ftp.download(WsnJian5,"/XZTL/XZTLJH.lua")
				end
				mSleep(100) toast("文件"..tostring(xh).."已更新",1)
			end
			JieTi = 2
		elseif JieTi == 2 then
			local ShuJu1 = readFileString(WsnJian1)
			local ShuJu2 = readFileString(WsnJian2)
			local ShuJu3 = readFileString(WsnJian3)
			local ShuJu4 = readFileString(WsnJian4)
			--local ShuJu5 = readFileString(WsnJian5)
			if ShuJu1 ~= "" and ShuJu2 ~= "" and ShuJu3 ~= "" and ShuJu4 ~= "" then 
			--if ShuJu1 ~= "" and ShuJu2 ~= "" and ShuJu3 ~= "" and ShuJu4 ~= "" and ShuJu5 ~= "" then 
				JieTi = nil break
			else
				local xh
				for xh= 1, 10 do
					mSleep(3000) toast("更新失败,等待重新更新",1)
				end
				JieTi = 1
			end
		end
	end
	mSleep(1000)
	ts.ftp.close()
	if WlDk==true then
		toast("已全部更新",1)
		WlDk=nil
	else
		mSleep(100) 
		setWifiEnable(false) 
		while (true) do
			toast("脚本已更新,停止运行后重启脚本......",1)
			mSleep(2000) 
		end
	end
end
function y_移动文件(path,to)
    os.execute("mv "..path.." "..to);
end
function f_复制文件(path,to)
    os.execute("cp -rf "..path.." "..to);
end
function j_检测文件(file_name)--检测指定文件是否存在
    local f = io.open(file_name, "r")
    return f ~= nil and f:close()
end
function j_加载_文件()
	local oldpath
	oldpath = userPath().."/res/XZJH.k"
	f_复制文件(oldpath,userPath().."/lua/XZJH.lua") 
	oldpath = nil
	oldpath = userPath().."/res/XZHS.k"
	f_复制文件(oldpath,userPath().."/lua/XZHS.lua") 
	oldpath = nil
	oldpath = userPath().."/res/XZUI.k"
	f_复制文件(oldpath,userPath().."/lua/XZUI.lua") 
	oldpath = nil
	oldpath = userPath().."/res/XZQS.k"
	f_复制文件(oldpath,userPath().."/lua/XZQS.lua") 
	oldpath = nil
	oldpath = userPath().."/res/TSLib.k"
	f_复制文件(oldpath,userPath().."/lua/TSLib.lua") 
	oldpath = nil
end
mSleep(1000) 
setWifiEnable(false) 
mSleep(2000) 
closeApp("com.xztl.ios",1)
mSleep(3000) 
b_版本号比较()
collectgarbage("collect") 
require("XZHS")
require("XZUI")
require("XZQS")
x_写配置("OldSs", SJiFanW(1, 9))
local WsnJian = "/private/var/mobile/Media/TouchSprite/res/BBH.lua"
local LsBbHnR = d_读配置("历史版本号")
local XzBbHnR = readFileString(WsnJian)  -- 读文件返回字符串
if LsBbHnR ~= XzBbHnR then
	toast("开始更新版本....", 1)
	x_写配置("历史版本号",XzBbHnR)
end
WsnJian,LsBbHnR,XzBbHnR = nil,nil,nil
mSleep(200) y_运行()
--k_开Boss卷轴()
--j_购买图鉴()
--z_整理背包()
--b_背包_格子物品()
--h_化身提升()
--f_分解圣兽()
--t_提升_漠影古都战力()
--t_提升_龙骸熔渊战力()
--k_开装备箱()
--h_滑动(294,525,295,139) 
--d_大地图(590,  287)--对应坐标位置
--mSleep(1000) ---测试用
--require("XZHS")
--require("XZUI")
--require("XZQS")
--toast("开始测试",1)
--k_开打_洞天福地()
--f_分解设置斗笠盾牌()

--g_关闭_魔龙魔龙()
--d_点(1100,  228) --打开背包
--Qsa=getColor(511,  300)
--Qsb=getColor(520,  301)
--Qsc=getColor(530,  301)
--Qsd=getColor(852,  321)
--Qse=getColor(502,  476)
--Qsf=getColor(394,  378)
--toast(Qsa,60)
--toast(Qsa.." "..Qsb.." "..Qsc,60)
--toast(Qsa.." "..Qsb.." "..Qsc.." "..Qsd,60)
--while (true) do
--	if b_遍历箱子() then
--		toast("识别了....",1)
--		mSleep(2000)
--	else
--		toast(".........",1)
--		mSleep(2000)
--	end
--	collectgarbage("collect")
--end
--while (true) do
--	mSleep(2000) local Qsa=getColor(331,  100)
--	if Qsa==1404928 then
--		mSleep(88) toast("颜色相等",1)
--	else
--		mSleep(88) toast(".........",1)
--	end
--end
--while (true) do
--	local x, y =s_识别_空格子(160,  150,165,  150)
--	if x~=-1 and y~=-1 then
--		mSleep(1000) toast(x.." "..y,1)
--	else
--		mSleep(1000)toast("无",1)
--	end
--end






