local socket = require("socket")
require("TSLib")
while (true) do
		local WwIp=getNetIP()
		if WwIp and WwIp ~= ""  then
			toast("网络已正常连接.....",1)
			mSleep(3000) WwIp=nil
			break
		else
			mSleep(3000) 
			toast("正在恢复网络连接,长久不连接请检查网络",1)
			setWifiEnable(true) 
		end
		WwIp=nil
	end
-- 创建一个 TCP 套接字
local client = socket.tcp()

-- 连接到服务器
local result, error = client:connect("127.0.0.1", 8080)

if not result then
    toast("连接失败: ".. error)
    return
end

-- 发送数据给服务器
local data = "这是来自客户端的消息"
client:send(data)

-- 接收服务器的响应
local response, error = client:receive()

if response then
    toast("收到服务器的响应: ".. response)
else
    toast("接收响应失败: ".. error)
end

-- 关闭连接
client:close()


	y_c(100) j_进入_大陆(95)
	y_c(2000) d_大地图(575,312)--走到八卦NPC
	y_c(6000) d_点(509,293)
	y_c(2000) local BgCk=s_识别_八卦窗口()
	if BgCk==true then
		y_c(1000) BgCk=nil
		--y_c(1000) d_点(839,137)--点吞噬
		local xh
		for xh= 1, 8 do
--			local BgXz=s_识别_八卦选择()
--			if BgXz==1 then
--				y_c(1000) d_点(643,439)--绿
--			elseif BgXz==2 then
--				y_c(1000) d_点(707,439)--蓝
--			elseif BgXz==3 then
--				y_c(1000) d_点(772,439)--紫
--			end
			if xh==1 then
				y_c(1000) d_点(412,234)
			elseif xh==2 then
				y_c(1000) d_点(483,264)
			elseif xh==3 then
				y_c(1000) d_点(502,329)
			elseif xh==4 then
				y_c(1000) d_点(476,389)
			elseif xh==5 then
				y_c(1000) d_点(413,413)
			elseif xh==6 then
				y_c(1000) d_点(335,392)
			elseif xh==7 then
				y_c(1000) d_点(313,315)
			elseif xh==8 then
				y_c(1000) d_点(340,257)
			end
			y_c(1000) 
			BgCk=s_识别_八卦窗口()
			if BgCk~=true then xh=nil return 
			else
				y_c(500) local YouXiDengLu=y_游戏登录()
				if YouXiDengLu==true then YouXiDengLu,xh=nil,nil return 
				else
					local BgXz=s_识别低级八卦()
					if BgXz==true then
						d_点(664,315)--点吞噬
						y_c(1500) d_点(848,501)--点吞噬
						y_c(1500) d_点(772,498)--点吞噬
					end
				end
			end
			local YgMlTs=s_刷新_弹窗提示()--提示远古魔狼刷新
			if YgMlTs==true then
				YgMlTs=nil
				y_c(1000) d_点(759,223)--点关闭刷新
			end
		end
		xh=nil
		y_c(1000) d_点(913,103)--点关闭刷新
	end






















