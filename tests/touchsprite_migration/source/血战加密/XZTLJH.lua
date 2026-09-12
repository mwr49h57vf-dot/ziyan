-- Obfuscated with LuaObfuscatorPro (Level 2)
init("0", 1);
require((""..string.char(84)..string.char(83)..string.char(76)..string.char(105)..string.char(98)..""))
ts = require("ts")
DXMC = (""..string.char(88)..string.char(90)..string.char(84)..string.char(76).."")
FuWuMing = (""..string.char(47)..string.char(88)..string.char(90)..string.char(84)..string.char(76)..string.char(47).."")
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
	local _tZogqLrrsBA = ts.config.get(sj)
	ts.config.close(true)
	sj = nil
	return _tZogqLrrsBA
end
function CheckFile(file_path)
	function FileHandle(file_name)
		local _UufDvHDiqcu = io.open(file_name, "r")
		file_name,file_path = nil,nil
		return _UufDvHDiqcu ~= nil and _UufDvHDiqcu:close()
	end
	local _IrIaEhsmRbtdViv = FileHandle(file_path)
	file_path=nil
	if _IrIaEhsmRbtdViv then
		return true
	else
		return false
	end
end
function DownFolder()
	local _OYKjbikFiK
	while (true) do
		_OYKjbikFiK=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
		if _OYKjbikFiK then 
			--连接服务器
			break
		else 
			mSleep(3000) --尝试与服务器连接
		end
	end
	_OYKjbikFiK=nil 
	mSleep(200)
	local _bVvgOfuIQbvQQfT=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _DzmVAFSARbdtC=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _NMIpjGquQyT=(""..string.char(47)..string.char(85)..string.char(115)..string.char(101)..string.char(114)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(108)..string.char(117)..string.char(97)..string.char(47).."")..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99).."")
	local _sLQEOGxAIaRhGy = 1
	while (true) do
		if _sLQEOGxAIaRhGy == 1 then
			local _vTAdbkgkCE
			for _vTAdbkgkCE= 1, 4 do
				if _vTAdbkgkCE==1 then
					ts.ftp.download(_bVvgOfuIQbvQQfT,FuWuMing..DXMC..(""..string.char(72)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				elseif _vTAdbkgkCE==2 then
					ts.ftp.download(_DzmVAFSARbdtC,FuWuMing..DXMC..(""..string.char(81)..string.char(83)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				elseif _vTAdbkgkCE==3 then
					ts.ftp.download(_NMIpjGquQyT,FuWuMing..DXMC..(""..string.char(85)..string.char(73)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..string.char(99)..""))
				end
				mSleep(100) --开始下载更新
			end
			_sLQEOGxAIaRhGy = 2
		elseif _sLQEOGxAIaRhGy == 2 then
			local _xoOYcvUEWVf = readFileString(_bVvgOfuIQbvQQfT)
			local _qObcTABbmd = readFileString(_DzmVAFSARbdtC)
			local _rNRuJOFyUgYRFbL = readFileString(_NMIpjGquQyT)
			if _xoOYcvUEWVf ~= " " and _qObcTABbmd ~= " " and _rNRuJOFyUgYRFbL ~= " " then 
				_sLQEOGxAIaRhGy = nil 
				break
			else
				local _vTAdbkgkCE
				for _vTAdbkgkCE= 1, 10 do
					mSleep(3000) --更新失败,等待重新更新
				end
				_sLQEOGxAIaRhGy = 1
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
		local _ZSCGZuMWeuqBOXL=getNetIP()
		if _ZSCGZuMWeuqBOXL and _ZSCGZuMWeuqBOXL ~= ""  then
			mSleep(100) _ZSCGZuMWeuqBOXL=nil
			break
		else
			setWifiEnable(false)
			mSleep(3000) 
			setWifiEnable(true)
			mSleep(10000)  
		end
		_ZSCGZuMWeuqBOXL=nil
	end
	local _OYKjbikFiK=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
	local _vTAdbkgkCE,_KgDXdkSrovmgJHW
	for _vTAdbkgkCE= 1, 15 do
		if _OYKjbikFiK then
			_KgDXdkSrovmgJHW = (""..string.char(47)..string.char(112)..string.char(114)..string.char(105)..string.char(118)..string.char(97)..string.char(116)..string.char(101)..string.char(47)..string.char(118)..string.char(97)..string.char(114)..string.char(47)..string.char(109)..string.char(111)..string.char(98)..string.char(105)..string.char(108)..string.char(101)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97).."")
			delFile(_KgDXdkSrovmgJHW)
			ts.ftp.download(_KgDXdkSrovmgJHW, FuWuMing..(""..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97)..""))
			mSleep(100) 
			ts.ftp.close()
			local _nKHWLQeYvn = ReadConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""))
			local _HwjKwMgZAnWu = readFileString(_KgDXdkSrovmgJHW)
			if _nKHWLQeYvn ~= _HwjKwMgZAnWu then
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
			_OYKjbikFiK=ts.ftp.connect((""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..string.char(46)..string.char(103)..string.char(111)..string.char(116)..string.char(111)..string.char(102)..string.char(116)..string.char(112)..string.char(49)..string.char(49)..string.char(46)..string.char(99)..string.char(111)..string.char(109)..""),(""..string.char(101)..string.char(110)..string.char(53)..string.char(51)..string.char(48)..string.char(50)..string.char(53)..string.char(53)..string.char(54)..string.char(56)..string.char(56)..""),(""..string.char(51)..string.char(49)..string.char(56)..string.char(54)..string.char(57)..string.char(54)..string.char(57)..string.char(97)..string.char(97)..""))
			mSleep(1000) 
		end
	end
	_vTAdbkgkCE, _OYKjbikFiK, _KgDXdkSrovmgJHW, _nKHWLQeYvn, _HwjKwMgZAnWu = nil, nil, nil, nil, nil
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
local _KgDXdkSrovmgJHW = (""..string.char(47)..string.char(112)..string.char(114)..string.char(105)..string.char(118)..string.char(97)..string.char(116)..string.char(101)..string.char(47)..string.char(118)..string.char(97)..string.char(114)..string.char(47)..string.char(109)..string.char(111)..string.char(98)..string.char(105)..string.char(108)..string.char(101)..string.char(47)..string.char(77)..string.char(101)..string.char(100)..string.char(105)..string.char(97)..string.char(47)..string.char(84)..string.char(111)..string.char(117)..string.char(99)..string.char(104)..string.char(83)..string.char(112)..string.char(114)..string.char(105)..string.char(116)..string.char(101)..string.char(47)..string.char(114)..string.char(101)..string.char(115)..string.char(47)..string.char(66)..string.char(66)..string.char(72)..string.char(46)..string.char(108)..string.char(117)..string.char(97).."")
local _nKHWLQeYvn = ReadConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""))
local _HwjKwMgZAnWu = readFileString(_KgDXdkSrovmgJHW)
if _nKHWLQeYvn ~= _HwjKwMgZAnWu then
	WriteConfig((""..string.char(86)..string.char(101)..string.char(114)..string.char(115)..string.char(105)..string.char(111)..string.char(110)..string.char(72)..string.char(105)..string.char(115)..string.char(116)..string.char(111)..string.char(114)..string.char(121)..""),_HwjKwMgZAnWu)
end
_KgDXdkSrovmgJHW,_nKHWLQeYvn,_HwjKwMgZAnWu = nil,nil,nil
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



























