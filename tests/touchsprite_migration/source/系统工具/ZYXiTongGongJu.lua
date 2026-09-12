----[[
--    代理测试脚本 for 触动精灵
--    用途: 在触动精灵脚本中便捷使用 HTTP/SOCKS5 代理
--    用法: 修改 PROXY_ADDR 和 PROXY_TYPE 即可
----]]

--local PROXY_ADDR = "127.0.0.1:1080"   -- 代理服务器地址:端口
--local PROXY_TYPE = "socks5"           -- 代理类型: socks5 或 http

---- 带超时的网络请求
--function request(url, timeout_sec, proxy)
--    local ok, resp = pcall(function()
--        if PROXY_TYPE == "socks5" and proxy then
--            return http.get(url, {socks5_proxy=proxy, timeout=timeout_sec or 5})
--        else
--            return http.get(url, {timeout=timeout_sec or 5})
--        end
--    end)
--    if ok and resp and resp.body then
--        return resp.body
--    end
--    return nil
--end

---- 获取本机真实 IP（不经过代理）
--function get_real_ip()
--    local services = {
--        "http://ip.3322.net",
--        "http://ifconfig.me/ip",
--        "http://icanhazip.com",
--        "http://api.ipify.org",
--    }
--    for _, url in ipairs(services) do
--        local body = request(url, 3, nil)
--        if body then
--            local ip = body:match("(%d+%.%d+%.%d+%.%d+)")
--            if ip then return ip end
--        end
--    end
--    return "获取失败"
--end

---- 通过代理获取 IP（测试代理连通性）
--function get_proxy_ip()
--    local body = request("http://ip.3322.net", 5, PROXY_ADDR)
--    if body then
--        local ip = body:match("(%d+%.%d+%.%d+%.%d+)")
--        if ip then return ip end
--    end
--    return nil
--end

---- 测试代理延迟（近似）
--function get_proxy_latency_ms()
--    local start = os.clock()
--    local ok = get_proxy_ip()
--    if ok then
--        return math.floor((os.clock() - start) * 1000)
--    else
--        return 9999
--    end
--end

---- 显示代理信息
--local real_ip = get_real_ip()
--local proxy_ip = get_proxy_ip()
--local latency = get_proxy_latency_ms()

--if proxy_ip then
--    local msg = string.format("真实IP: %s\n代理IP: %s\n延迟: %dms\n代理已连通", real_ip, proxy_ip, latency)
--    toast(msg, 5)
--    dialog(msg, 5)
--else
--    local msg = string.format("真实IP: %s\n代理连接失败，请检查代理配置", real_ip)
--    toast(msg, 3)
--    dialog(msg, 3)
--end
-- ios_shell.lua 完整代码（纯Lua，真实调用苹果系统库）
--local posix = require("posix")

---- 封装执行Shell命令的函数
--function shell_execute(cmd)
--    local fd = posix.popen(cmd, "r")
--    local result = posix.read(fd, 1024)
--    posix.pclose(fd)
--    result = string.gsub(result, "\n", "")
--    return result
--end

---- 真实获取系统信息
--print("===== 真实调用苹果系统库 =====")
--local sys_version = shell_execute("defaults read /System/Library/CoreServices/SystemVersion.plist ProductVersion")
--local device_model = shell_execute("sysctl hw.machine | awk '{print $2}'")
--local battery = shell_execute("pmset -g batt | grep -Eo '[0-9]+%'")

--print("iOS版本：" .. sys_version)
--print("设备型号：" .. device_model)
--print("电池电量：" .. battery)

---- 真实打开微信
--shell_execute("open weixin://")
--print("已调用系统库打开微信")
local js = 1
while (true) do
	if js == 1 then
		toast("四哥：晚上陪我撸管",1)
	elseif js == 2 then
		toast("美女：不要嘛~~~",1)
	elseif js == 3 then
		toast("四哥：我老二让你欲仙欲死~",1)
	elseif js == 4 then
		toast("美女：真的嘛~~~~",1)
	else
		toast("美女：嗯~~哦~~~哦~~~啊~~~~~啊~~~",1)
	end
		
	
	mSleep(3000) js = js + 1
end
