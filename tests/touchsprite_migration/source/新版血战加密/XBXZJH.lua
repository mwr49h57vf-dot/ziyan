-- Obfuscated with LuaObfuscatorPro (Level 2)
init("0", 1);
require((""..string.char(84)..string.char(83)..string.char(76)..string.char(105)..string.char(98)..""))
ts = require("ts")
DXMC = (""..string.char(88)..string.char(66)..string.char(88)..string.char(90).."")
FuWuMing = (""..string.char(47)..string.char(88)..string.char(66)..string.char(88)..string.char(90)..string.char(47).."")
BiaoShiFu = (""..string.char(99)..string.char(111)..string.char(109)..string.char(46)..string.char(120)..string.char(122)..string.char(116)..string.char(108)..string.char(46)..string.char(105)..string.char(111)..string.char(115).."")
function WriteConfig(mb,lx)
	ts.config.open((""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(83)..string.char(121)..string.char(115)..string.char(116)..string.char(101)..string.char(109)..string.char(46)..string.char(112)..string.char(108)..string.char(105)..string.char(115)..string.char(116)..""))
	ts.config.delete(mb)
	ts.config.save(mb,lx)
	ts.config.close(true)
	mb,lx = nil,nil
end
function ReadConfig(sj)
	ts.config.open((""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(83)..string.char(121)..string.char(115)..string.char(116)..string.char(101)..string.char(109)..string.char(46)..string.char(112)..string.char(108)..string.char(105)..string.char(115)..string.char(116)..""))
	local _lKoyQxoWThkX = ts.config.get(sj)
	ts.config.close(true)
	sj = nil
	return _lKoyQxoWThkX
end
function CheckFile(file_path)
	function FileHandle(file_name)
		local _GsKMfESLXNunh = io.open(file_name, "r")
		file_name,file_path = nil,nil
		return _GsKMfESLXNunh ~= nil and _GsKMfESLXNunh:close()
	end
	local _MJLcrJMRUZlgTtFJ = FileHandle(file_path)
	file_path=nil
	if _MJLcrJMRUZlgTtFJ then
		return true
	else
		return false
	end
end
function DownFolder()
	local _zNvioCvzkjpLxF
	while (true) do
		_zNvioCvzkjpLxF=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
		if _zNvioCvzkjpLxF then 
			--连接服务器
			break
		else 
			mSleep(3000) --尝试与服务器连接
		end
	end
	_zNvioCvzkjpLxF=nil 
	mSleep(200)
	local _PxPNhNglhPx=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _MKIAMwqgeMup=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _ePasHUNfYUpaUrQo=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _MzeKKOkROOQME = 1
	while (true) do
		if _MzeKKOkROOQME == 1 then
			local _OOTabIDsbK
			for _OOTabIDsbK= 1, 4 do
				if _OOTabIDsbK==1 then
					ts.ftp.download(_PxPNhNglhPx,FuWuMing..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				elseif _OOTabIDsbK==2 then
					ts.ftp.download(_MKIAMwqgeMup,FuWuMing..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				elseif _OOTabIDsbK==3 then
					ts.ftp.download(_ePasHUNfYUpaUrQo,FuWuMing..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				end
				mSleep(100) --开始下载更新
			end
			_MzeKKOkROOQME = 2
		elseif _MzeKKOkROOQME == 2 then
			local _qlDgJQiIVUR = readFileString(_PxPNhNglhPx)
			local _JvkOEFyYbjayPU = readFileString(_MKIAMwqgeMup)
			local _nmccHiJZYXncbJB = readFileString(_ePasHUNfYUpaUrQo)
			if _qlDgJQiIVUR ~= " " and _JvkOEFyYbjayPU ~= " " and _nmccHiJZYXncbJB ~= " " then 
				_MzeKKOkROOQME = nil 
				break
			else
				local _OOTabIDsbK
				for _OOTabIDsbK= 1, 10 do
					mSleep(3000) --更新失败,等待重新更新
				end
				_MzeKKOkROOQME = 1
			end
		end
	end
	mSleep(200)
	ts.ftp.close()
end
function VersionCompare()
	setWifiEnable(true)
	mSleep(2000) 
	while (true) do
		local _CntCZTwaljpr=getNetIP()
		if _CntCZTwaljpr and _CntCZTwaljpr ~= ""  then
			mSleep(100) _CntCZTwaljpr=nil
			break
		else
			setWifiEnable(false)
			mSleep(3000) 
			setWifiEnable(true)
			mSleep(10000)  
		end
		_CntCZTwaljpr=nil
	end
	local _zNvioCvzkjpLxF=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
	local _OOTabIDsbK,_rGqDAPwVeVJp
	for _OOTabIDsbK= 1, 15 do
		if _zNvioCvzkjpLxF then
			_rGqDAPwVeVJp = (""..string.char(47)..string.char(112)..string.char(114)..string.char(105)..string.char(118)..string.char(97)..string.char(116)..string.char(101)..string.char(47)..string.char(118)..string.char(97)..string.char(114)..string.char(47)..string.char(109)..string.char(111)..string.char(98)..string.char(105)..string.char(108)..string.char(101)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97).."")
			delFile(_rGqDAPwVeVJp)
			ts.ftp.download(_rGqDAPwVeVJp, FuWuMing..(""..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""))
			mSleep(100) 
			ts.ftp.close()
			local _AvPWZFhzzzzio = ReadConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""))
			local _iHIAPrzXNd = readFileString(_rGqDAPwVeVJp)
			if _AvPWZFhzzzzio ~= _iHIAPrzXNd then
				mSleep(200)
				DownFolder()
				mSleep(200)
				break
			else
				--判断文件是否存在
				if CheckFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")) == false or
					CheckFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")) == false or
					CheckFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")) == false 
				then 
					DownFolder()
					mSleep(200)
				end
				break
			end
		else
			_zNvioCvzkjpLxF=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
			mSleep(1000) 
		end
	end
	_OOTabIDsbK, _zNvioCvzkjpLxF, _rGqDAPwVeVJp, _AvPWZFhzzzzio, _iHIAPrzXNd = nil, nil, nil, nil, nil
end
function safeDeleteFile(path,newpath)
	if os.execute((""..string.char(99)..string.char(112)..string.char(32)..string.char(45)..string.char(114)..string.char(102)..string.char(32).."")..path.." "..newpath)then
		if os.remove(path) then return end
	end
	mSleep(100) safeDeleteFile(path,newpath)
end
mSleep(100) 
setWifiEnable(false) 
closeApp(BiaoShiFu,1)
VersionCompare()
local _rGqDAPwVeVJp = (""..string.char(47)..string.char(112)..string.char(114)..string.char(105)..string.char(118)..string.char(97)..string.char(116)..string.char(101)..string.char(47)..string.char(118)..string.char(97)..string.char(114)..string.char(47)..string.char(109)..string.char(111)..string.char(98)..string.char(105)..string.char(108)..string.char(101)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97).."")
local _AvPWZFhzzzzio = ReadConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""))
local _iHIAPrzXNd = readFileString(_rGqDAPwVeVJp)
if _AvPWZFhzzzzio ~= _iHIAPrzXNd then
	WriteConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""),_iHIAPrzXNd)
end
_rGqDAPwVeVJp,_AvPWZFhzzzzio,_iHIAPrzXNd = nil,nil,nil
safeDeleteFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""),userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""))
safeDeleteFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""),userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""))
safeDeleteFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""),userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""))
require(DXMC.."HS")
require(DXMC.."UI")
safeDeleteFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""),userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
safeDeleteFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""),userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
safeDeleteFile(userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""),userPath()..(""..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
collectgarbage((""..string.char(99)..string.char(111)..string.char(108)..string.char(108)..string.char(101)..string.char(99)..string.char(116).."")) 
mSleep(200) 
StartScript()



