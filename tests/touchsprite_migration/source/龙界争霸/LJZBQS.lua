require("TSLib")
local ts = require("ts")
local sz = require("sz")
function d_多色坐标(Rgb, Pprgb, Xsd, Zba, Zbb, Zbc, Zbd)
	Xsd = Xsd or 85
	local x,y = findMultiColorInRegionFuzzy(Rgb, Pprgb, Xsd, Zba , Zbb , Zbc , Zbd )
	return x,y
end
function C_存在多色(Rgb, Pprgb, Xsd, Zba, Zbb, Zbc, Zbd)
	Xsd = Xsd or 85
	local x,y=d_多色坐标(Rgb, Pprgb, Xsd, Zba, Zbb, Zbc, Zbd)
	if x~=-1 then return true end
end
function d_单色坐标(Rgb, Xsd, Zba, Zbb, Zbc, Zbd)-- 模糊找单色
	Xsd = Xsd or 85
	local x,y = findColorInRegionFuzzy(Rgb,Xsd,Zba,Zbb,Zbc,Zbd)
	return x,y 
end
function c_存在单色(Rgb,Xsd,Zba,Zbb,Zbc,Zbd)
	Xsd = Xsd or 85
	local x,y=d_单色坐标(Rgb, Xsd, Zba, Zbb, Zbc, Zbd)
	if x~=-1 then return true end
end
function d_单点比色(Zba, Zbb)-- 单点对比颜色
	local Qsa = getColor(Zba, Zbb)
	mSleep(300)
	local Qsb = getColor(Zba, Zbb)
	return Qsa == Qsb--返回true的意思
end
function d_单色匹配(name)
	local BRCYMLSD = {
        ["安全区"] = {
            {0x00ff00, 1000,  141, 1040,  152},
        },
    }
	if type(name) ~= "string" then  toast("[错误] 地图编号参数必须为字符串类型") return end
    local configList = BRCYMLSD[name]
    if not configList then toast("[错误] 未找到编号为[" .. name .. "]的配置") return end
    for i, item in ipairs(configList) do
        -- 调用颜色校验函数，任意一项不满足则直接返回
        if c_存在单色(item[1], 80, item[2], item[3], item[4], item[5]) then return true end
    end
end
function d_单色不同参数(argument)
	local CanShu = {
			["材料不足"] = {
				{0xff0000, 734,  448, 739,  458},--战力材料不足
				{0xff0000, 720,  429, 767,  440},--战力元宝不足
				{0xff0000, 794,  399, 821,  411},--等级不足
				{0xff0000, 734,  401, 774,  427},--提升元宝不足
			},
			["基础设置"] = {
				{0xfffd9c, 647,  158, 647,  158},--数字飘血
				{0xfffd9c, 646,  240, 646,  240},--数字飘血
				{0xfffd9c, 645,  279, 645,  279},--数字飘血
				{0xfffd9c, 647,  318, 647,  318},--数字飘血
				
				{0xfffd9c, 865,  159, 865,  159},--数字飘血
				{0xfffd9c, 866,  198, 866,  198},--数字飘血
				{0xfffd9c, 866,  238, 866,  238},--数字飘血
				{0xfffd9c, 866,  278, 866,  278},--数字飘血
				{0xfffd9c, 865,  319, 865,  319},--数字飘血
				{0xfffd9c, 865,  360, 865,  360},--数字飘血
				{0xfffd9c, 866,  398, 866,  398},--数字飘血
				
				{0xfffd9c, 536,  502, 536,  502},--数字飘血
				{0xfffd9c, 876,  504, 876,  504},--数字飘血
			},
		}
	if type(argument) ~= "string" then  toast("[错误] 地图编号参数必须为字符串类型") return end
    local configList = CanShu[argument]
    if not configList then toast("[错误] 未找到编号为[" .. argument .. "]的配置") return end
    for i, item in ipairs(configList) do
        -- 调用颜色校验函数，任意一项不满足则直接返回
        if c_存在单色(item[1], 80, item[2], item[3], item[4], item[5]) then return i end
    end
	return 0
end
function z_找色返坐标(name)
	local PiPei = {
		["大陆石"] = {
            {0xfef7bc, "0|1|0xfbf4b9,0|2|0xf7efb5,0|3|0xf3eab1", 401,  480,401,  483},
            {0xfef7bc, "0|1|0xfbf4b9,0|2|0xf7efb5,0|3|0xf3eab1", 454,  480,454,  483},
            {0xfef7bc, "0|1|0xfbf4b9,0|2|0xf7efb5,0|3|0xf3eab1", 507,  480,507,  483},
			{0xfef7bc, "0|1|0xfbf4b9,0|2|0xf7efb5,0|3|0xf3eab1", 560,  480,560,  483},
            {0xfef7bc, "0|1|0xfbf4b9,0|2|0xf7efb5,0|3|0xf3eab1", 613,  480,613,  483},
            {0xfef7bc, "0|1|0xfbf4b9,0|2|0xf7efb5,0|3|0xf3eab1", 666,  480,666,  483},
        },
		["随机石"] = {
            {0xf7efb5, "1|0|0xf7efb5,2|0|0xece5ad,3|0|0xece5ad", 402,  482,405,  482},
            {0xf7efb5, "1|0|0xf7efb5,2|0|0xece5ad,3|0|0xece5ad", 455,  482,458,  482},
			{0xf7efb5, "1|0|0xf7efb5,2|0|0xece5ad,3|0|0xece5ad", 508,  482,511,  482},
            {0xf7efb5, "1|0|0xf7efb5,2|0|0xece5ad,3|0|0xece5ad", 561,  482,564,  482},
			{0xf7efb5, "1|0|0xf7efb5,2|0|0xece5ad,3|0|0xece5ad", 614,  482,617,  482},
            {0xf7efb5, "1|0|0xf7efb5,2|0|0xece5ad,3|0|0xece5ad", 667,  482,670,  482},
        },
		["回城石"] = {
            {0xfbf4b9, "1|0|0xfbf4b9,2|0|0xfbf4b9,3|0|0xfbf4b9", 401,  481,404,  481},
            {0xfbf4b9, "1|0|0xfbf4b9,2|0|0xfbf4b9,3|0|0xfbf4b9", 453,  481,456,  481},
			{0xfbf4b9, "1|0|0xfbf4b9,2|0|0xfbf4b9,3|0|0xfbf4b9", 506,  481,509,  481},
            {0xfbf4b9, "1|0|0xfbf4b9,2|0|0xfbf4b9,3|0|0xfbf4b9", 559,  481,562,  481},
			{0xfbf4b9, "1|0|0xfbf4b9,2|0|0xfbf4b9,3|0|0xfbf4b9", 612,  481,615,  481},
            {0xfbf4b9, "1|0|0xfbf4b9,2|0|0xfbf4b9,3|0|0xfbf4b9", 665,  481,668,  481},
        },
	}
	local PinLei = PiPei[name]
	for i, item in ipairs(PinLei) do
        local x,y = d_多色坐标(item[1], item[2],70,item[3], item[4], item[5], item[6])
		if x~=-1 then return x, y end
    end
	return -1,-1
end
function d_多色匹配(name)
	local BRCYMLSD = {
        ["公告"] = {
            {0xbabbcd, "1|0|0xbbbdce,2|0|0xbdc0ce,3|0|0xbcbecc",233,501,236,501},
			{0xbfc1cf, "1|0|0xbfc1cf,2|0|0xbfc1cf,3|0|0xbcbecc",893,501,896,501},
        },
		["启动"] = {
            {0xf5e7c9, "0|1|0xf5e7c9,0|2|0xf5e7c9,0|3|0xf5e7c9",550,425,550,428},
			{0xe8dabf, "0|1|0xeee1c4,0|2|0xf5e7c9,0|3|0xf5e7c9",583,419,583,422},
        },
		["开始"] = {
            {0xac987d, "1|0|0xac987d,2|0|0xac987d,3|0|0xac987d",206,535,209,535},
			{0xac987d, "1|0|0xac987d,2|0|0xac987d,3|0|0xac987d",220,596,223,596},
        },
		["角色1"] = {
            {0x5c574c, "0|1|0x545047,1|1|0x76736c,1|2|0x6d6b64",400,516,401,518},
			{0x797770, "1|0|0x76736c,2|0|0x6a6760,3|0|0x746f66",392,513,395,513},
        },
		["角色2"] = {
            {0xc2beb2, "0|1|0xb4b0a5,1|1|0xa6a192,1|2|0xa6a192",401,517,402,519},
			{0xe6e3db, "0|1|0xe6e3db,0|2|0xe7e3da,0|3|0xe9e4d9",460,514,460,517},
        },
		["连接超时"] = {
            {0xffffff, "0|1|0xffffff,0|2|0xffffff,0|3|0xffffff",365,259,365,262},
			{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",430,265,433,265},
			{0xd0d0cf, "1|0|0xcfcfce,0|1|0xffffff,1|1|0xffffff",493,264,494,265},
			{0xf0efef, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",733,370,736,370},
        },
		["您已掉线"] = {
            {0xffffff, "0|1|0xffffff,0|2|0xffffff,0|3|0xffffff",365,257,365,260},
			{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",384,259,387,259},
			{0xd0cfcf, "1|0|0xcecece,0|1|0xffffff,1|1|0xffffff",429,264,430,265},
			{0xf1f0ef, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",613,370,616,370},
        },
		["游戏维护"] = {
            {0xffffff, "1|0|0xffffff,2|0|0xffffff,2|1|0xf2f2f2",459,258,461,259},
			{0xf1f1f0, "1|1|0xffffff,2|2|0xdadada,3|2|0xffffff",491,255,494,257},
			{0xd0d0cf, "1|0|0xcfcfce,0|1|0xffffff,1|1|0xffffff",557,264,558,265},
			{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",736,374,739,374},
        },
		["停止战斗"] = {
            {0x958f7f, "1|0|0xa8a290,2|0|0xbfb8a4,3|0|0xe5deca",1042,291,1045,291},
        },
		["活动图标"] = {
            {0xdad4ae, "1|0|0xe2dcb2,2|0|0xddd4a8,3|0|0xdfd8ad",965,27,968,27},
        },
		["传奇之路窗口"] = {
            {0xffc34d, "0|1|0xffb744,0|2|0xfdba49,1|2|0xfecd55",1013,72,1014,74},
        },
		["大地图窗口"] = {
            {0xfcef96, "1|0|0xfcec8b,0|1|0xfcec8b,1|1|0xfdf29c",965,88,966,89},
        },
		["地图传送"] = {
            {0x676665, "1|0|0x676665,2|0|0x676665,3|0|0x727170",481,596,484,596},
			{0x676665, "1|0|0x676665,2|0|0x676665,3|0|0x676665",837,596,840,596},
        },
		["盟重省"] = {
            {0xffffff, "0|1|0xffffff,0|2|0xffffff,0|3|0xffffff",1048,18,1048,21},
			{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",1061,18,1064,18},
			{0xcececd, "1|1|0xf5f5f4,2|2|0xf9f9f9,3|3|0xededed",1085,9,1088,12},
			{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",1081,20,1084,20},
        },
		["玛法之城"] = {
            {0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",1041,19,1044,19},
			{0xffffff, "0|1|0xd9d9d8,1|1|0xe1e1e0,1|2|0xffffff",1062,19,1063,21},
			{0xaeaead, "0|1|0xfbfafa,1|2|0xfefefe,1|3|0xffffff",1073,8,1074,11},
			{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",1088,14,1091,14},
        },
    }
	if type(name) ~= "string" then  toast("[错误] 地图编号参数必须为字符串类型") return end
    local configList = BRCYMLSD[name]
    if not configList then toast("[错误] 未找到编号为[" .. name .. "]的配置") return end
    for i, item in ipairs(configList) do
        -- 调用颜色校验函数，任意一项不满足则直接返回
        if not C_存在多色(item[1], item[2], 80, item[3], item[4], item[5], item[6]) then return end
    end
    return true
end
function d_多色不同参数(argument)
	local CanShu = {
			["大陆传送位置"] = {
				{0xfcfcfc, "1|1|0xf9f9f9,2|1|0x3a3a3a,2|2|0xfbfafa,3|2|0xfefefe",617,142,620,144},
				{0x8d8c8b, "0|1|0xb2b1b1,1|1|0xffffff,2|1|0x999897,2|2|0xfefefe",614,138,616,140},
				{0xa5a4a3, "1|0|0xfefefe,1|1|0xf0efef,2|1|0xd5d4d4,2|2|0xf6f6f6",614,132,616,134},
				{0xf4f3f3, "1|0|0xcdcdcc,1|1|0xd4d3d3,2|1|0xfdfdfd,2|2|0xc9c8c8",608,137,610,139},
				{0xf8f8f8, "0|1|0x908f8e,1|1|0xffffff,2|2|0xfefefe,3|2|0xbbbab9",618,132,621,134},
				{0xeeeeee, "0|1|0xffffff,0|2|0xffffff,0|3|0xffffff,0|4|0xa2a1a0",615,140,615,144},
			},
			["识别幻境"] = {
				{0xe8dfda, "0|1|0xe1d6cf,0|2|0xd9ccc4,0|3|0xd2c3b9",250,132,250,135},
				{0xffffff, "0|1|0xfffefe,0|2|0xf3ece8,1|3|0xf4ede9,2|4|0xd0c1b6",270,131,272,135},
			},
			["识别状态栏"] = {
				{0xc8b88c, "0|1|0xfdf1ae,0|2|0xfdf297,0|3|0xf8e48b",1083,355,1083,358},
				{0x796a3f, "0|1|0x796a3f,0|2|0x6c5b3b,0|3|0x6c5b3b,0|4|0x74613e",1005,366,1005,370},
			},
			["使用包裹经验"] = {
				{0xccc8b9, "0|1|0xc7c1a5,0|2|0xc7c1a5,0|3|0xc4bc9c",171,131,171,134},
				{0x97948b, "1|0|0x97948b,2|0|0x97948b,3|0|0x7d7a72",170,130,173,130},
				{0x9f896a, "1|0|0x9f896a,2|0|0x9f896a,3|0|0x9f896a",359,538,362,538},
				{0xf5efd5, "0|1|0xf5efd5,0|2|0xf5efd5,0|3|0xf7e7c0",164,130,164,133},
				{0x97948a, "1|0|0x97948a,2|0|0x97948a,3|0|0x97948a",163,129,166,129},
			},
			["11大陆放入位置"] = {
				{0xe2d2a7, "1|0|0xe2d2a7,2|0|0xe2d2a7,3|0|0xe2d2a7",457,271,460,271},
				{0xe2d2a7, "1|0|0xe2d2a7,2|0|0xe2d2a7,3|0|0xe2d2a7",524,271,527,271},
				{0xe2d2a7, "1|0|0xe2d2a7,2|0|0xe2d2a7,3|0|0xe2d2a7",591,271,594,271},
				{0xe2d2a7, "1|0|0xe2d2a7,2|0|0xe2d2a7,3|0|0xe2d2a7",658,271,661,271},
				{0xe2d2a7, "1|0|0xe2d2a7,2|0|0xe2d2a7,3|0|0xe2d2a7",725,271,728,271},
			},
			["识别降妖谱"] = {
				{0x53a07d, "0|1|0x53a07d,0|2|0x53a07d,0|3|0x53a07d",732,62,732,65},
				{0x53a07d, "0|1|0x53a07d,0|2|0x53a07d,0|3|0x53a07d",654,62,654,65},
			},
			["激活降妖谱"] = {
				{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",437,444,440,444},
				{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",571,444,574,444},
				{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",705,444,708,444},
				{0xffffff, "1|0|0xffffff,2|0|0xffffff,3|0|0xffffff",839,444,842,444},
				{0xa6291a, "1|0|0xa6291a,2|0|0xa6291a,3|0|0xa6291a",872,509,875,509},--套装激活
			},
			["获取降妖谱"] = {
				{0xe3e3e2, "0|1|0xe3e3e2,0|2|0xe3e3e2,0|3|0xe3e3e2",398,438,398,441},
				{0xe3e3e2, "0|1|0xe3e3e2,0|2|0xe3e3e2,0|3|0xe3e3e2",532,438,532,441},
				{0xe3e3e2, "0|1|0xe3e3e2,0|2|0xe3e3e2,0|3|0xe3e3e2",666,438,666,441},
				{0xe3e3e2, "0|1|0xe3e3e2,0|2|0xe3e3e2,0|3|0xe3e3e2",800,438,800,441},
			},
			["幻境降妖谱"] = {
				{0xdedddb, "0|1|0xe6e6e6,0|2|0xe6e6e6,0|3|0xdedddb",398,438,398,441},
				{0xdedddb, "0|1|0xe6e6e6,0|2|0xe6e6e6,0|3|0xdedddb",532,438,532,441},
				{0xdedddb, "0|1|0xe6e6e6,0|2|0xe6e6e6,0|3|0xdedddb",666,438,666,441},
				{0xdedddb, "0|1|0xe6e6e6,0|2|0xe6e6e6,0|3|0xdedddb",800,438,800,441},
			},
			["混元宝珠"] = {
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",833,421,836,421},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",416,445,419,445},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",684,232,687,232},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",509,265,512,265},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",376,207,379,207},
			},
			["龙虎如意"] = {
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",630,422,633,422},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",800,363,803,363},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",327,318,330,318},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",378,170,381,170},
				{0xff0000, "1|0|0xff0000,2|0|0xff0000,3|0|0xff0000",761,170,764,170},
			},
			["左下怪"] = {
				{0xe6bf30, "1|1|0xe6bf30,2|2|0xe6bf30,3|3|0xe6bf30",191,240,194,243},
				{0xff0000, "0|1|0xff0000,0|2|0xff0000,0|3|0xff0000",47,252,47,255},
				{0xbfa769, "1|0|0xbea668,2|0|0xbca466,3|0|0xb39a5c",23,240,26,240},
			},
			["黄河阵任务"] = {
				{0xb0a893, "1|0|0xb0a893,2|0|0xb9b8b7,3|0|0xe6e5e5",524,456,527,456},
				{0xb1b0ad, "1|0|0xa59f89,2|0|0xbebdba,3|0|0xe4e3e3",524,456,527,456},
				{0xafa893, "1|0|0xafa893,2|0|0xb8b7b5,3|0|0xefefee",524,456,527,456},
			},
		}
	if type(argument) ~= "string" then  toast("[错误] 地图编号参数必须为字符串类型") return end
    local configList = CanShu[argument]
    if not configList then toast("[错误] 未找到编号为[" .. argument .. "]的配置") return end
    for i, item in ipairs(configList) do
        -- 调用颜色校验函数，任意一项不满足则直接返回
        if C_存在多色(item[1], item[2], 80, item[3], item[4], item[5], item[6]) then return i end
    end
	return 0
end
function d_多色坐标参数(argument)
	local CanShu = {
		["Boss卷轴"] = {
			{0x95c9e9, "1|0|0x99cae8,2|0|0x90c0dd,3|0|0x91adac,4|0|0xd3d29c,5|0|0xa9a787,6|0|0xb4aa80,7|0|0xa9986f",149,130,606,385},
			{0x516a46, "1|0|0x628451,2|0|0x709a58,3|0|0x6e9555,4|0|0x65864d,5|0|0x557848,6|0|0x43603a,7|0|0x314831",149,130,606,385},
		},
		["Boss点位"] = {
			{0xe9e6e2, "1|0|0xd7d1cc,2|0|0xd4cfca,3|0|0xeceae6",239,  119,878,  502},
			{0xe9e7e2, "1|0|0xd7d2cc,2|0|0xd4cfc9,3|0|0xeceae5",239,  119,878,  502},
			{0xe9e7e2, "1|0|0xd8d3cd,2|0|0xd4cfc9,3|0|0xeceae5",239,  119,878,  502},
		},
	}
	if type(argument) ~= "string" then  toast("[错误] 地图编号参数必须为字符串类型") return end
    local configList = CanShu[argument]
    if not configList then toast("[错误] 未找到编号为[" .. argument .. "]的配置") return end
    for i, item in ipairs(configList) do
        local x,y = d_多色坐标(item[1], item[2], 80, item[3], item[4], item[5], item[6])
        if x ~= -1 then return x,y end
    end
	return -1,-1
end
