-- Obfuscated with LuaObfuscatorPro (Level 2)
init("0", 1);
require((""..string.char(84)..string.char(83)..string.char(76)..string.char(105)..string.char(98)..""))
ts = require("ts")
DXMC = (""..string.char(83)..string.char(74)..string.char(88)..string.char(84).."")
FuWuMing = (""..string.char(47)..string.char(83)..string.char(74)..string.char(88)..string.char(84)..string.char(47).."")
BiaoShiFu = (""..string.char(99)..string.char(111)..string.char(109)..string.char(46)..string.char(115)..string.char(106)..string.char(120)..string.char(116)..string.char(102)..string.char(103)..string.char(103)..string.char(98)..string.char(98)..string.char(46)..string.char(103)..string.char(97)..string.char(109)..string.char(101).."")
function WriteConfig(mb,lx)
	ts.config.open((""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(83)..string.char(121)..string.char(115)..string.char(116)..string.char(101)..string.char(109)..string.char(46)..string.char(112)..string.char(108)..string.char(105)..string.char(115)..string.char(116)..""))
	ts.config.delete(mb)
	ts.config.save(mb,lx)
	ts.config.close(true)
	mb,lx = nil,nil
end
function ReadConfig(sj)
	ts.config.open((""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(83)..string.char(121)..string.char(115)..string.char(116)..string.char(101)..string.char(109)..string.char(46)..string.char(112)..string.char(108)..string.char(105)..string.char(115)..string.char(116)..""))
	local _bfWRSKEdHgzNHcme = ts.config.get(sj)
	ts.config.close(true)
	sj = nil
	return _bfWRSKEdHgzNHcme
end
function CheckFile(file_path)
	function FileHandle(file_name)
		local _IFLTZbDNxkLGr = io.open(file_name, "r")
		file_name,file_path = nil,nil
		return _IFLTZbDNxkLGr ~= nil and _IFLTZbDNxkLGr:close()
	end
	local _uEBMiYlIOmxzcyk = FileHandle(file_path)
	file_path=nil
	if _uEBMiYlIOmxzcyk then
		return true
	else
		return false
	end
end
function DownFolder()
	local _ggHEvzvVpVp
	while (true) do
		_ggHEvzvVpVp=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
		if _ggHEvzvVpVp then 
			--连接服务器
			break
		else 
			mSleep(3000) --尝试与服务器连接
		end
	end
	_ggHEvzvVpVp=nil 
	mSleep(200)
	local _KYoeBLOtmkkYh=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _oECEkbnJQITzFA=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _CekftIPCpseaqs=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _kVEpfasbdGT = 1
	while (true) do
		if _kVEpfasbdGT == 1 then
			local _UlusdfgHjyYicJJ
			for _UlusdfgHjyYicJJ= 1, 4 do
				if _UlusdfgHjyYicJJ==1 then
					ts.ftp.download(_KYoeBLOtmkkYh,FuWuMing..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				elseif _UlusdfgHjyYicJJ==2 then
					ts.ftp.download(_oECEkbnJQITzFA,FuWuMing..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				elseif _UlusdfgHjyYicJJ==3 then
					ts.ftp.download(_CekftIPCpseaqs,FuWuMing..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				end
				mSleep(100) --开始下载更新
			end
			_kVEpfasbdGT = 2
		elseif _kVEpfasbdGT == 2 then
			local _untzsvECLLhir = readFileString(_KYoeBLOtmkkYh)
			local _sFupyizFaEQEQG = readFileString(_oECEkbnJQITzFA)
			local _YYoNlYPLaV = readFileString(_CekftIPCpseaqs)
			if _untzsvECLLhir ~= " " and _sFupyizFaEQEQG ~= " " and _YYoNlYPLaV ~= " " then 
				_kVEpfasbdGT = nil 
				break
			else
				local _UlusdfgHjyYicJJ
				for _UlusdfgHjyYicJJ= 1, 10 do
					mSleep(3000) --更新失败,等待重新更新
				end
				_kVEpfasbdGT = 1
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
		local _bbIMdnCAxatvB=getNetIP()
		if _bbIMdnCAxatvB and _bbIMdnCAxatvB ~= ""  then
			mSleep(100) _bbIMdnCAxatvB=nil
			break
		else
			setWifiEnable(false)
			mSleep(3000) 
			setWifiEnable(true)
			mSleep(10000)  
		end
		_bbIMdnCAxatvB=nil
	end
	local _ggHEvzvVpVp=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
	local _UlusdfgHjyYicJJ,_ZWCICCUaDfLLwl
	for _UlusdfgHjyYicJJ= 1, 15 do
		if _ggHEvzvVpVp then
			_ZWCICCUaDfLLwl = (""..string.char(47)..string.char(112)..string.char(114)..string.char(105)..string.char(118)..string.char(97)..string.char(116)..string.char(101)..string.char(47)..string.char(118)..string.char(97)..string.char(114)..string.char(47)..string.char(109)..string.char(111)..string.char(98)..string.char(105)..string.char(108)..string.char(101)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97).."")
			delFile(_ZWCICCUaDfLLwl)
			ts.ftp.download(_ZWCICCUaDfLLwl, FuWuMing..(""..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""))
			mSleep(100) 
			ts.ftp.close()
			local _OlDCHtoSnRsQKac = ReadConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""))
			local _RyBxJlZbyuYwQRG = readFileString(_ZWCICCUaDfLLwl)
			if _OlDCHtoSnRsQKac ~= _RyBxJlZbyuYwQRG then
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
			_ggHEvzvVpVp=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
			mSleep(1000) 
		end
	end
	_UlusdfgHjyYicJJ, _ggHEvzvVpVp, _ZWCICCUaDfLLwl, _OlDCHtoSnRsQKac, _RyBxJlZbyuYwQRG = nil, nil, nil, nil, nil
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
local _ZWCICCUaDfLLwl = (""..string.char(47)..string.char(112)..string.char(114)..string.char(105)..string.char(118)..string.char(97)..string.char(116)..string.char(101)..string.char(47)..string.char(118)..string.char(97)..string.char(114)..string.char(47)..string.char(109)..string.char(111)..string.char(98)..string.char(105)..string.char(108)..string.char(101)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97).."")
local _OlDCHtoSnRsQKac = ReadConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""))
local _RyBxJlZbyuYwQRG = readFileString(_ZWCICCUaDfLLwl)
if _OlDCHtoSnRsQKac ~= _RyBxJlZbyuYwQRG then
	WriteConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""),_RyBxJlZbyuYwQRG)
end
_ZWCICCUaDfLLwl,_OlDCHtoSnRsQKac,_RyBxJlZbyuYwQRG = nil,nil,nil
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
RunGame()



































