#import "ZiYanScriptGenerator.h"
#import "ZiYanLLMSidecarClient.h"
#import "ZiYanLiveVisionLearn.h"
#import "ZiYanPaths.h"
#import <sys/stat.h>
#import <unistd.h>
#import <time.h>

@implementation ZiYanScriptGenerator

+ (NSString *)sanitizeFileBase:(NSString *)name {
  NSMutableString *s = [NSMutableString stringWithString:name ?: @"app"];
  NSCharacterSet *ok = [NSCharacterSet
      characterSetWithCharactersInString:
          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (![ok characterIsMember:c]) {
      [s replaceCharactersInRange:NSMakeRange(i, 1) withString:@"_"];
    }
  }
  if (s.length == 0) {
    return @"gen_app";
  }
  NSString *low = s.lowercaseString;
  if ([low isEqualToString:@"ios7"] || [low isEqualToString:@"ios8p"] ||
      [low hasPrefix:@"_zy_auto"]) {
    return [NSString stringWithFormat:@"gen_%@", s];
  }
  return s;
}

+ (NSString *)gameFamilyForApp:(ZiYanAppPick *)app {
  NSString *bid = (app.bundleId ?: @"").lowercaseString;
  NSString *name = app.displayName ?: @"";
  if ([bid containsString:@"xztl"] || [name containsString:@"血战"]) {
    // 新版血战优先 xbxz 若 index 有；默认 xztl
    return @"xztl";
  }
  if ([bid containsString:@"ychj"] || [bid containsString:@"hlhj"] ||
      [name containsString:@"赤沙"]) {
    return @"cslc";
  }
  if ([name containsString:@"怒剑"] || [bid containsString:@"njcq"]) {
    return @"njcq";
  }
  if ([name containsString:@"圣戒"] || [bid containsString:@"sjxt"]) {
    return @"sjxt";
  }
  if ([name containsString:@"龙界"] || [bid containsString:@"ljzb"] ||
      [bid containsString:@"badao"]) {
    return @"ljzb";
  }
  if ([name containsString:@"新版血战"] || [bid containsString:@"xbxz"]) {
    return @"xbxz";
  }
  return @"generic";
}

+ (NSString *)knowledgeRoot {
  return ZiYanKnowledgeDirectory();
}

+ (nullable NSDictionary *)loadFamilyDoc:(NSString *)family {
  if (family.length == 0 || [family isEqualToString:@"generic"]) {
    return nil;
  }
  NSArray *cands = @[
    [[self knowledgeRoot]
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"families/%@.json", family]],
    [NSString stringWithFormat:
                  @"/private/var/mobile/Media/ZiYan/ZYCV/res/knowledge/families/%@.json",
                  family],
    [NSString stringWithFormat:
                  @"/private/var/mobile/Media/ZiYan/knowledge/families/%@.json",
                  family],
    [NSString
        stringWithFormat:@"/usr/lib/ziyan/share/media_seed/knowledge/families/%@.json",
                         family],
    [NSString stringWithFormat:
                  @"/var/jb/usr/lib/ziyan/share/media_seed/knowledge/families/%@.json",
                  family],
  ];
  for (NSString *p in cands) {
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d.length)
      continue;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]] &&
        [obj[@"imported"] boolValue]) {
      return obj;
    }
  }
  return nil;
}

/// 公告/维护等误入 login 会导致反复点灰条、阶段假成功 → 重新分桶
+ (NSDictionary *)rebucketPhases:(NSDictionary *)phases {
  NSMutableDictionary *out = [@{
    @"login" : [NSMutableArray array],
    @"server" : [NSMutableArray array],
    @"role" : [NSMutableArray array],
    @"enter" : [NSMutableArray array],
    @"battle" : [NSMutableArray array],
    @"popup" : [NSMutableArray array],
  } mutableCopy];
  if (![phases isKindOfClass:[NSDictionary class]])
    return out;
  NSRegularExpression *rxPopup = [NSRegularExpression
      regularExpressionWithPattern:@"公告|维护|确定|关闭|同意|领取|知道了|掉线"
                           options:0
                             error:nil];
  NSRegularExpression *rxLogin = [NSRegularExpression
      regularExpressionWithPattern:@"登录|账号|密码|游客|隐私"
                           options:0
                             error:nil];
  NSRegularExpression *rxServer = [NSRegularExpression
      regularExpressionWithPattern:@"区服|服务器|选服"
                           options:0
                             error:nil];
  NSRegularExpression *rxRole = [NSRegularExpression
      regularExpressionWithPattern:@"角色|选角|创建角"
                           options:0
                             error:nil];
  NSRegularExpression *rxEnter = [NSRegularExpression
      regularExpressionWithPattern:@"进入|开始游戏|开服"
                           options:0
                             error:nil];
  NSRegularExpression *rxBattle = [NSRegularExpression
      regularExpressionWithPattern:
          @"挂机|自动|技能|助手|攻击|随机石|回城|回收|宝库|齿轮|背包|传送"
                           options:0
                             error:nil];
  NSRegularExpression *rxPopupOnly = [NSRegularExpression
      regularExpressionWithPattern:
          @"公告|维护|确定|关闭|同意|领取|知道了|掉线|下次再说"
                           options:0
                             error:nil];
  void (^add)(NSString *, id) = ^(NSString *key, id it) {
    NSMutableArray *arr = out[key];
    if (arr)
      [arr addObject:it];
  };
  BOOL (^match)(NSRegularExpression *, NSString *) =
      ^BOOL(NSRegularExpression *rx, NSString *lab) {
        if (!rx || lab.length == 0)
          return NO;
        return [rx numberOfMatchesInString:lab
                                   options:0
                                     range:NSMakeRange(0, lab.length)] > 0;
      };
  for (NSString *pk in phases) {
    id arr = phases[pk];
    if (![arr isKindOfClass:[NSArray class]])
      continue;
    for (id it in (NSArray *)arr) {
      if (![it isKindOfClass:[NSDictionary class]])
        continue;
      NSString *lab = [it[@"label"] description] ?: @"";
      // R8.4.11：Critic 几何补桶（geo_y_*）优先保留 phase，避免乱码 OCR 全进 battle
      NSString *crit = [it[@"critic"] description] ?: @"";
      NSString *forcedPh = [it[@"phase"] description] ?: @"";
      if ([crit hasPrefix:@"geo_y_"] && forcedPh.length && out[forcedPh]) {
        add(forcedPh, it);
        continue;
      }
      // 弹窗白名单：禁止业务按钮（回收/宝库等）误入 popup 导致 login 乱点
      if (match(rxPopupOnly, lab))
        add(@"popup", it);
      else if (match(rxLogin, lab))
        add(@"login", it);
      else if (match(rxServer, lab))
        add(@"server", it);
      else if (match(rxRole, lab))
        add(@"role", it);
      else if (match(rxEnter, lab))
        add(@"enter", it);
      else if (match(rxBattle, lab) || [pk isEqualToString:@"battle"] ||
               [pk isEqualToString:@"main"])
        add(@"battle", it);
      else if (out[pk] && ![pk isEqualToString:@"popup"])
        add(pk, it);
      else if (match(rxPopup, lab))
        add(@"popup", it);
      else if (forcedPh.length && out[forcedPh])
        add(forcedPh, it);
      else
        add(@"battle", it);
    }
  }
  return out;
}

/// R8.4.7：去重 + 优先级排序 + 每阶段最多 8 条（避免全表扫描拖死循环）
+ (NSInteger)colorLabelPriority:(NSString *)lab {
  if ([lab containsString:@"挂机"] || [lab containsString:@"自动战斗"])
    return 0;
  if ([lab containsString:@"自动"] || [lab containsString:@"小助手"])
    return 1;
  if ([lab containsString:@"登录"] || [lab containsString:@"游客"] ||
      [lab containsString:@"进入游戏"] || [lab containsString:@"开始游戏"])
    return 1;
  if ([lab containsString:@"选择角色"] || [lab containsString:@"创建角色"])
    return 2;
  if ([lab containsString:@"关闭"] || [lab containsString:@"确定"])
    return 2;
  if ([lab containsString:@"随机石"] || [lab containsString:@"回城"])
    return 8;
  return 5;
}

+ (NSString *)luaColorRows:(NSArray *)arr {
  if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) {
    return @"  -- empty\n";
  }
  NSMutableArray *accepted = [NSMutableArray array];
  NSMutableDictionary *labCount = [NSMutableDictionary dictionary];
  for (id it in arr) {
    if (![it isKindOfClass:[NSDictionary class]])
      continue;
    NSString *lab = [it[@"label"] description] ?: @"step";
    NSInteger cnt = [labCount[lab] integerValue];
    if (cnt >= 2)
      continue; // 同名最多 2 条
    NSString *first = it[@"first"] ?: @"0xffffff";
    NSString *off = it[@"off"] ?: @"0|1|0xffffff";
    unsigned int rgb = 0;
    NSScanner *sc = [NSScanner scannerWithString:first];
    if ([first hasPrefix:@"0x"] || [first hasPrefix:@"0X"])
      sc.scanLocation = 2;
    [sc scanHexInt:&rgb];
    int r = (rgb >> 16) & 0xff, g = (rgb >> 8) & 0xff, b = rgb & 0xff;
    BOOL nearGray = abs(r - g) < 20 && abs(g - b) < 20 && abs(r - b) < 20;
    BOOL popupish = [lab containsString:@"公告"] || [lab containsString:@"维护"] ||
                    [lab containsString:@"掉线"] || [lab containsString:@"服务器维护"];
    if (popupish)
      continue;
    if (nearGray && (r + g + b) > 180 && (r + g + b) < 600) {
      // 登录/进入类按钮偶为浅灰底，保留
      if (!([lab containsString:@"登录"] || [lab containsString:@"游客"] ||
            [lab containsString:@"免密"] || [lab containsString:@"进入"] ||
            [lab containsString:@"开始"] || [lab containsString:@"角色"] ||
            [lab containsString:@"自动"] || [lab containsString:@"挂机"])) {
        continue;
      }
    }
    int deg = [it[@"degree"] intValue];
    if (deg < 50)
      deg = 85;
    int x1 = [it[@"x1"] intValue], y1 = [it[@"y1"] intValue];
    int x2 = [it[@"x2"] intValue], y2 = [it[@"y2"] intValue];
    if (abs(x2 - x1) < 8) {
      int cx = (x1 + x2) / 2;
      x1 = MAX(0, cx - 24);
      x2 = cx + 24;
    }
    if (abs(y2 - y1) < 8) {
      int cy = (y1 + y2) / 2;
      y1 = MAX(0, cy - 24);
      y2 = cy + 24;
    }
    labCount[lab] = @(cnt + 1);
    [accepted addObject:@{
      @"label" : lab,
      @"first" : first,
      @"off" : off,
      @"degree" : @(deg),
      @"x1" : @(x1),
      @"y1" : @(y1),
      @"x2" : @(x2),
      @"y2" : @(y2),
      @"pri" : @([self colorLabelPriority:lab]),
    }];
  }
  [accepted sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    NSInteger pa = [a[@"pri"] integerValue], pb = [b[@"pri"] integerValue];
    if (pa < pb)
      return NSOrderedAscending;
    if (pa > pb)
      return NSOrderedDescending;
    return NSOrderedSame;
  }];
  NSMutableString *s = [NSMutableString string];
  NSUInteger n = 0;
  for (NSDictionary *it in accepted) {
    NSString *lab = [it[@"label"] description];
    lab = [lab stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    lab = [lab stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    [s appendFormat:
           @"  {label=\"%@\", first=%@, off=\"%@\", degree=%d, x1=%d,y1=%d,x2=%d,"
            @"y2=%d},\n",
           lab, it[@"first"], it[@"off"], [it[@"degree"] intValue],
           [it[@"x1"] intValue], [it[@"y1"] intValue], [it[@"x2"] intValue],
           [it[@"y2"] intValue]];
    if (++n >= 8)
      break;
  }
  if (n == 0)
    return @"  -- empty\n";
  return s;
}

/// R8.4.8：TS keepScreen 热路径 — 一批找色共一帧；tap 后才 invalidate；OCR 稀触发
+ (NSString *)fullBusinessLuaForApp:(ZiYanAppPick *)app
                         resProfile:(NSString *)profile
                         gameFamily:(NSString *)family
                                doc:(NSDictionary *_Nullable)doc {
  NSString *bid = app.bundleId ?: @"unknown";
  NSString *name = app.displayName ?: bid;
  NSString *fam = family.length ? family : @"generic";
  NSDictionary *phases = [doc[@"phases"] isKindOfClass:[NSDictionary class]]
                             ? doc[@"phases"]
                             : @{};
  if (phases.count == 0 &&
      [doc[@"COLOR_PARAMS"] isKindOfClass:[NSArray class]]) {
    NSMutableDictionary *bucket = [@{
      @"login" : [NSMutableArray array],
      @"server" : [NSMutableArray array],
      @"role" : [NSMutableArray array],
      @"enter" : [NSMutableArray array],
      @"battle" : [NSMutableArray array],
      @"popup" : [NSMutableArray array]
    } mutableCopy];
    for (id it in (NSArray *)doc[@"COLOR_PARAMS"]) {
      if (![it isKindOfClass:[NSDictionary class]])
        continue;
      NSString *ph = [it[@"phase"] description] ?: @"main";
      NSMutableArray *arr = bucket[ph];
      if (!arr)
        continue;
      [arr addObject:it];
    }
    phases = bucket;
  }
  phases = [self rebucketPhases:phases];
  NSString *loginRows = [self luaColorRows:phases[@"login"]];
  NSString *serverRows = [self luaColorRows:phases[@"server"]];
  NSString *roleRows = [self luaColorRows:phases[@"role"]];
  NSString *enterRows = [self luaColorRows:phases[@"enter"]];
  NSString *battleRows = [self luaColorRows:phases[@"battle"]];
  NSString *popupRows = [self luaColorRows:phases[@"popup"]];
  // login 无色参时：借 enter 前 4 条作启动链 fallback（避免纯 OCR 拖慢）
  if ([loginRows containsString:@"-- empty"] && enterRows.length > 12) {
    NSMutableString *fb = [NSMutableString string];
    NSArray *enterArr = phases[@"enter"];
    if ([enterArr isKindOfClass:[NSArray class]]) {
      NSUInteger n = 0;
      for (id it in enterArr) {
        if (![it isKindOfClass:[NSDictionary class]])
          continue;
        NSString *lab = [it[@"label"] description] ?: @"enter";
        NSString *first = it[@"first"] ?: @"0xffffff";
        NSString *off = it[@"off"] ?: @"0|1|0xffffff";
        int deg = [it[@"degree"] intValue];
        if (deg < 50)
          deg = 85;
        int x1 = [it[@"x1"] intValue], y1 = [it[@"y1"] intValue];
        int x2 = [it[@"x2"] intValue], y2 = [it[@"y2"] intValue];
        [fb appendFormat:
                  @"  {label=\"%@\", first=%@, off=\"%@\", degree=%d, x1=%d,y1=%d,x2=%d,"
                   @"y2=%d},\n",
                  lab, first, off, deg, x1, y1, x2, y2];
        if (++n >= 4)
          break;
      }
    }
    if (fb.length > 8)
      loginRows = fb;
  }
  BOOL imported = [doc[@"imported"] boolValue];

  return [NSString
      stringWithFormat:
          @"-- ZiYan full business R8.4.9 live-OCR-color (family=%@ imported=%@)\n"
          @"-- app=%@ bid=%@\n"
          @"-- 色参来源：开游 OCR 识字 + 周边自动 getColor（禁人工采集）\n"
          @"-- flow: boot→login→role→enter→battle→loop | color-first\n"
          @"local BID = \"%@\"\n"
          @"local RES = { profile = \"%@\", family = \"%@\", imported = %@ }\n"
          @"local OCR_COOL_S, LOOP_MS, SLEEP_MIN, OCR_EVERY = 8, 500, 300, 12\n"
          @"local deadline = os.time() + 7200\n"
          @"local STATE = \"boot\"\n"
          @"local LW, LH = 1136, 640\n"
          @"local LAST = { lab = \"\", t = 0 }\n"
          @"local HITN = {}\n"
          @"local LEARN_N = 0\n"
          @"local PHASE_DEADLINE = 0\n"
          @"local _ocr_last, _ocr_cache = 0, \"\"\n"
          @"local _popup_last = 0\n"
          @"local _frame_on = false\n"
          @"local _loop_tick = 0\n"
          @"\n"
          @"local PHASE = {\n"
          @"  login = {\n%@  },\n"
          @"  server = {\n%@  },\n"
          @"  role = {\n%@  },\n"
          @"  enter = {\n%@  },\n"
          @"  battle = {\n%@  },\n"
          @"  popup = {\n%@  },\n"
          @"}\n"
          @"\n"
          @"local function sleep_ms(ms)\n"
          @"  if ms < SLEEP_MIN then ms = SLEEP_MIN end\n"
          @"  mSleep(ms)\n"
          @"end\n"
          @"\n"
          @"local function var_dir()\n"
          @"  if type(ZIYAN_VAR) == \"string\" and #ZIYAN_VAR > 0 then return ZIYAN_VAR end\n"
          @"  if io.open(\"/var/jb/usr/lib/ziyan/var\", \"r\") then return \"/var/jb/usr/lib/ziyan/var\" end\n"
          @"  return \"/usr/lib/ziyan/var\"\n"
          @"end\n"
          @"\n"
          @"local function frame_off()\n"
          @"  if _frame_on and type(keepScreen) == \"function\" then pcall(keepScreen, false) end\n"
          @"  _frame_on = false\n"
          @"end\n"
          @"\n"
          @"local function frame_on()\n"
          @"  if not _frame_on and type(keepScreen) == \"function\" then\n"
          @"    pcall(keepScreen, true)\n"
          @"    _frame_on = true\n"
          @"  end\n"
          @"end\n"
          @"\n"
          @"local function after_tap()\n"
          @"  frame_off()\n"
          @"  sleep_ms(450)\n"
          @"end\n"
          @"\n"
          @"local function screen_size()\n"
          @"  if type(getScreenSize) == \"function\" then\n"
          @"    local a,b = getScreenSize(); if a and b and a>0 then LW,LH=a,b end\n"
          @"  end\n"
          @"  return LW, LH\n"
          @"end\n"
          @"\n"
          @"local function cooled(lab)\n"
          @"  local now = os.time()\n"
          @"  if lab and lab == LAST.lab and now - LAST.t < 5 then return true end\n"
          @"  LAST.lab = lab or \"\"; LAST.t = now\n"
          @"  return false\n"
          @"end\n"
          @"\n"
          @"local function mark(p)\n"
          @"  STATE = p\n"
          @"  pcall(function()\n"
          @"    local f = io.open(var_dir() .. \"/.ziyan_script_phase\", \"w\")\n"
          @"    if f then f:write(tostring(p) .. \"\\n\"); f:close() end\n"
          @"  end)\n"
          @"end\n"
          @"\n"
          @"local function hit_limit(lab)\n"
          @"  local k = tostring(lab or \"\")\n"
          @"  HITN[k] = (HITN[k] or 0) + 1\n"
          @"  return HITN[k] > 2\n"
          @"end\n"
          @"\n"
          @"local function ocr_text()\n"
          @"  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return \"\" end\n"
          @"  local now = os.time()\n"
          @"  if now - _ocr_last < OCR_COOL_S then return _ocr_cache end\n"
          @"  _ocr_last = now\n"
          @"  frame_off()\n"
          @"  screen_size()\n"
          @"  local txt = \"\"\n"
          @"  if type(getText) == \"function\" then\n"
          @"    local ok, t = pcall(getText, 0, 0, -1, -1)\n"
          @"    if ok and t then txt = tostring(t) end\n"
          @"  end\n"
          @"  _ocr_cache = txt or \"\"\n"
          @"  return _ocr_cache\n"
          @"end\n"
          @"\n"
          @"local function find_text_xy(word)\n"
          @"  frame_off(); screen_size()\n"
          @"  if type(findStr) == \"function\" then\n"
          @"    local ok, x, y = pcall(findStr, word, 0, 0, LW, LH)\n"
          @"    if ok and x and x >= 0 and y and y >= 0 then return x, y, \"findStr\" end\n"
          @"  end\n"
          @"  return -1, -1, nil\n"
          @"end\n"
          @"\n"
          @"local function sample_off(x, y)\n"
          @"  if type(getColor) ~= \"function\" then return nil, nil end\n"
          @"  local c0 = tonumber(getColor(x, y)) or 0\n"
          @"  local c1 = tonumber(getColor(x + 2, y)) or c0\n"
          @"  local c2 = tonumber(getColor(x, y + 2)) or c0\n"
          @"  local c3 = tonumber(getColor(x + 2, y + 2)) or c0\n"
          @"  local off = string.format(\"2|0|0x%%06X,0|2|0x%%06X,2|2|0x%%06X\", c1, c2, c3)\n"
          @"  return c0, off\n"
          @"end\n"
          @"\n"
          @"local function do_learn(label, x, y, via)\n"
          @"  LEARN_N = LEARN_N + 1\n"
          @"  if type(learn) == \"function\" then pcall(learn, label, x, y, via, BID)\n"
          @"  elseif type(gameRemember) == \"function\" then pcall(gameRemember, label, x, y, via, BID) end\n"
          @"end\n"
          @"\n"
          @"local function find_one(st)\n"
          @"  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return -1, -1 end\n"
          @"  if type(findMultiColorInRegionFuzzy) ~= \"function\" then return -1, -1 end\n"
          @"  local x1,y1,x2,y2 = st.x1, st.y1, st.x2, st.y2\n"
          @"  if not x1 or not y1 then return -1, -1 end\n"
          @"  if math.abs((x2 or x1) - x1) < 8 then x1 = math.max(0, x1 - 24); x2 = x1 + 48 end\n"
          @"  if math.abs((y2 or y1) - y1) < 8 then y1 = math.max(0, y1 - 24); y2 = y1 + 48 end\n"
          @"  local x, y = findMultiColorInRegionFuzzy(st.first, st.off, st.degree or 85, x1, y1, x2, y2)\n"
          @"  return x or -1, y or -1\n"
          @"end\n"
          @"\n"
          @"local function try_colors(list)\n"
          @"  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return false, nil, nil end\n"
          @"  if type(list) ~= \"table\" or #list == 0 then return false, nil, nil end\n"
          @"  frame_on(); screen_size()\n"
          @"  for _, st in ipairs(list) do\n"
          @"    local lab = tostring(st.label)\n"
          @"    if (HITN[lab] or 0) > 2 then goto cont_c end\n"
          @"    if cooled(\"色:\" .. lab) then goto cont_c end\n"
          @"    local x, y = find_one(st)\n"
          @"    if x ~= -1 then\n"
          @"      if hit_limit(lab) then goto cont_c end\n"
          @"      toast(\"色:\" .. lab, 500)\n"
          @"      tap(x, y)\n"
          @"      do_learn(lab, x, y, \"findMulti\")\n"
          @"      after_tap()\n"
          @"      return true, lab, \"color\"\n"
          @"    end\n"
          @"    ::cont_c::\n"
          @"  end\n"
          @"  return false, nil, nil\n"
          @"end\n"
          @"\n"
          @"local function try_ocr_keys(ocr_keys)\n"
          @"  if PHASE_DEADLINE > 0 and os.time() >= PHASE_DEADLINE then return false, nil, nil end\n"
          @"  if type(ocr_keys) ~= \"table\" or #ocr_keys == 0 then return false, nil, nil end\n"
          @"  local txt = ocr_text()\n"
          @"  if #txt == 0 then return false, nil, nil end\n"
          @"  for _, w in ipairs(ocr_keys) do\n"
          @"    if string.find(txt, w, 1, true) then\n"
          @"      if cooled(\"OCR:\" .. w) then goto cont_o end\n"
          @"      if hit_limit(\"OCR:\" .. w) then goto cont_o end\n"
          @"      local fx, fy, via = find_text_xy(w)\n"
          @"      if fx >= 0 then\n"
          @"        toast(\"OCR:\" .. w, 500)\n"
          @"        tap(fx, fy)\n"
          @"        local c0, off = sample_off(fx, fy)\n"
          @"        if c0 then\n"
          @"          do_learn(\"色参:\" .. w, fx, fy, string.format(\"0x%%06X\", c0))\n"
          @"        end\n"
          @"        do_learn(w, fx, fy, via or \"ocr\")\n"
          @"        sleep_ms(700)\n"
          @"        return true, w, \"ocr\"\n"
          @"      end\n"
          @"      ::cont_o::\n"
          @"    end\n"
          @"  end\n"
          @"  return false, nil, nil\n"
          @"end\n"
          @"\n"
          @"local function try_phase(list, ocr_keys)\n"
          @"  -- 色参优先（对齐 Ai代码训练 JH 热路径）；无色参再 OCR\n"
          @"  local ok, lab, via = try_colors(list)\n"
          @"  if ok then return ok, lab, via end\n"
          @"  if type(list) ~= \"table\" or #list == 0 then\n"
          @"    return try_ocr_keys(ocr_keys)\n"
          @"  end\n"
          @"  -- 有色参时 OCR 仅作兜底，且受 OCR_COOL_S 限制\n"
          @"  return try_ocr_keys(ocr_keys)\n"
          @"end\n"
          @"\n"
          @"local function txt_has(txt, keys)\n"
          @"  for _, w in ipairs(keys) do\n"
          @"    if string.find(txt, w, 1, true) then return true end\n"
          @"  end\n"
          @"  return false\n"
          @"end\n"
          @"\n"
          @"local function dismiss_popups()\n"
          @"  local now = os.time()\n"
          @"  if try_colors(PHASE.popup) then return true end\n"
          @"  if now - _popup_last < OCR_COOL_S then return false end\n"
          @"  _popup_last = now\n"
          @"  return try_ocr_keys({\"关闭\",\"确定\",\"我知道了\",\"同意\",\"下次再说\"})\n"
          @"end\n"
          @"\n"
          @"local function ensure_front()\n"
          @"  local path = var_dir() .. \"/.ziyan_front_bid\"\n"
          @"  local f = io.open(path, \"r\")\n"
          @"  local front = f and f:read(\"*l\") or \"\"\n"
          @"  if f then f:close() end\n"
          @"  if front == BID then return true end\n"
          @"  runApp(BID)\n"
          @"  sleep_ms(2500)\n"
          @"  return true\n"
          @"end\n"
          @"\n"
          @"function phase_login()\n"
          @"  mark(\"login\")\n"
          @"  toast(\"phase:login\", 700)\n"
          @"  local t0 = os.time()\n"
          @"  PHASE_DEADLINE = os.time() + 25\n"
          @"  while os.time() - t0 < 90 do\n"
          @"    if os.time() - t0 > 25 then toast(\"phase:login:soft\", 500); return true end\n"
          @"    ensure_front(); dismiss_popups()\n"
          @"    local txt = ocr_text()\n"
          @"    if txt_has(txt, {\"进入游戏\",\"开始游戏\",\"选择角色\",\"创建角色\",\"区服\"}) then return true end\n"
          @"    local ok, lab = try_phase(PHASE.login, {\"登录\",\"免密登录\",\"游客登录\",\"进入\",\"开始游戏\"})\n"
          @"    if ok then\n"
          @"      sleep_ms(900)\n"
          @"      txt = ocr_text()\n"
          @"      if not txt_has(txt, {\"登录\",\"账号\",\"密码\"}) or txt_has(txt, {\"进入游戏\",\"角色\",\"区服\"}) then return true end\n"
          @"    end\n"
          @"    if try_colors(PHASE.enter) then return true end\n"
          @"    if try_colors(PHASE.role) then return true end\n"
          @"    sleep_ms(LOOP_MS)\n"
          @"  end\n"
          @"  return true\n"
          @"end\n"
          @"\n"
          @"function phase_role_select()\n"
          @"  mark(\"role\")\n"
          @"  toast(\"phase:role\", 700)\n"
          @"  local t0 = os.time()\n"
          @"  PHASE_DEADLINE = os.time() + 28\n"
          @"  while os.time() - t0 < 90 do\n"
          @"    if os.time() - t0 > 28 then toast(\"phase:role:soft\", 500); return true end\n"
          @"    ensure_front(); dismiss_popups()\n"
          @"    local txt = ocr_text()\n"
          @"    if txt_has(txt, {\"进入游戏\",\"开始游戏\"}) and not txt_has(txt, {\"登录\"}) then\n"
          @"      try_colors(PHASE.enter); return true\n"
          @"    end\n"
          @"    try_colors(PHASE.server)\n"
          @"    if try_phase(PHASE.role, {\"选择角色\",\"创建角色\",\"角色\"}) then\n"
          @"      sleep_ms(800)\n"
          @"      txt = ocr_text()\n"
          @"      if txt_has(txt, {\"进入游戏\",\"开始\",\"挂机\",\"自动\"}) then return true end\n"
          @"    end\n"
          @"    if try_colors(PHASE.enter) then return true end\n"
          @"    sleep_ms(LOOP_MS)\n"
          @"  end\n"
          @"  return true\n"
          @"end\n"
          @"\n"
          @"function phase_enter_game()\n"
          @"  mark(\"enter\")\n"
          @"  toast(\"phase:enter\", 700)\n"
          @"  local t0 = os.time()\n"
          @"  PHASE_DEADLINE = os.time() + 30\n"
          @"  while os.time() - t0 < 90 do\n"
          @"    if os.time() - t0 > 30 then toast(\"phase:enter:soft\", 500); STATE = \"main\"; return true end\n"
          @"    ensure_front(); dismiss_popups()\n"
          @"    local txt = ocr_text()\n"
          @"    if txt_has(txt, {\"挂机\",\"自动战斗\",\"小助手\",\"技能\"}) then STATE = \"main\"; return true end\n"
          @"    if try_phase(PHASE.enter, {\"进入游戏\",\"开始游戏\",\"进入\"}) then sleep_ms(1600); STATE = \"main\"; return true end\n"
          @"    if try_colors(PHASE.battle) then STATE = \"main\"; return true end\n"
          @"    sleep_ms(LOOP_MS)\n"
          @"  end\n"
          @"  return true\n"
          @"end\n"
          @"\n"
          @"function phase_auto_battle()\n"
          @"  mark(\"battle\")\n"
          @"  toast(\"phase:battle\", 700)\n"
          @"  local t0 = os.time()\n"
          @"  local hit = false\n"
          @"  PHASE_DEADLINE = 0\n"
          @"  while os.time() - t0 < 45 do\n"
          @"    ensure_front()\n"
          @"    if os.time() - t0 > 8 then dismiss_popups() end\n"
          @"    -- 热路径：只色找，不每轮 OCR\n"
          @"    if try_colors(PHASE.battle) then hit = true; toast(\"loop:afk\", 400) end\n"
          @"    sleep_ms(LOOP_MS)\n"
          @"    if hit and os.time() - t0 > 5 then break end\n"
          @"    if os.time() - t0 > 18 and not hit then\n"
          @"      try_ocr_keys({\"挂机\",\"自动战斗\",\"自动\"})\n"
          @"      toast(\"loop:afk\", 400); break\n"
          @"    end\n"
          @"  end\n"
          @"  return hit\n"
          @"end\n"
          @"\n"
          @"function check_state_and_handle()\n"
          @"  _loop_tick = _loop_tick + 1\n"
          @"  ensure_front()\n"
          @"  if dismiss_popups() then return end\n"
          @"  if try_colors(PHASE.battle) then return end\n"
          @"  if try_colors(PHASE.enter) then return end\n"
          @"  if try_colors(PHASE.role) then return end\n"
          @"  if _loop_tick %% OCR_EVERY ~= 1 then return end\n"
          @"  local txt = ocr_text()\n"
          @"  if txt_has(txt, {\"登录\",\"账号\",\"密码\"}) then phase_login(); return end\n"
          @"  if txt_has(txt, {\"角色\",\"区服\",\"选服\"}) then phase_role_select(); return end\n"
          @"  if txt_has(txt, {\"进入游戏\",\"开始游戏\"}) then phase_enter_game(); return end\n"
          @"end\n"
          @"\n"
          @"function main()\n"
          @"  init(1)\n"
          @"  frame_off()\n"
          @"  screen_size()\n"
          @"  toast(\"gen-R8.4.8:\" .. \"%@\", 1200)\n"
          @"  runApp(BID)\n"
          @"  sleep_ms(4000)\n"
          @"  ensure_front()\n"
          @"  if type(syncGameScreen) == \"function\" then syncGameScreen(1, BID)\n"
          @"  elseif type(gameSync) == \"function\" then gameSync(1, BID) end\n"
          @"  frame_off()\n"
          @"  phase_login()\n"
          @"  phase_role_select()\n"
          @"  phase_enter_game()\n"
          @"  phase_auto_battle()\n"
          @"  _loop_tick = 0\n"
          @"  while os.time() < deadline do\n"
          @"    check_state_and_handle()\n"
          @"    sleep_ms(LOOP_MS)\n"
          @"  end\n"
          @"  frame_off()\n"
          @"  if type(codegen) == \"function\" then pcall(codegen, BID)\n"
          @"  elseif type(gameCodegen) == \"function\" then pcall(gameCodegen, BID) end\n"
          @"end\n"
          @"\n"
          @"main()\n",
          fam, imported ? @"true" : @"false", name, bid, bid,
          profile ?: @"iphone7_13", fam, imported ? @"true" : @"false",
          loginRows, serverRows, roleRows, enterRows, battleRows,
          popupRows.length ? popupRows : @"  -- none\n", name];
}

+ (NSString *)ensureBootstrapChain:(NSString *)lua bid:(NSString *)bid {
  if (lua.length < 8 || bid.length == 0)
    return lua;
  if ([lua containsString:@"phase_login"] && [lua containsString:@"runApp("]) {
    return lua;
  }
  // 侧车残缺稿：直接换完整业务稿更安全
  return lua;
}

#pragma mark - R8.4.11 Fable-style local Agent (P→V→K→G；T 在 UI)

+ (NSDictionary *)agentPlanForApp:(ZiYanAppPick *)app
                           family:(NSString *)family
                          profile:(NSString *)profile {
  return @{
    @"goal" : @"auto_script_login_role_enter_battle",
    @"family" : family ?: @"generic",
    @"bid" : app.bundleId ?: @"",
    @"res_profile" : profile ?: @"iphone7_13",
    @"success" : @{
      @"live_color_min" : @1,
      @"prefer_phase_colors" : @[ @"login", @"role", @"enter" ],
      @"run_phases_min" : @2,
    },
    @"max_vision_rounds" : @3,
    @"max_test_retries" : @1,
    @"paid_api" : @NO,
    @"note" : @"borrow_fable_workflow_local_only",
  };
}

+ (NSDictionary *)phaseBucketCounts:(NSDictionary *)doc {
  NSDictionary *ph = [doc[@"phases"] isKindOfClass:[NSDictionary class]]
                         ? doc[@"phases"]
                         : @{};
  NSMutableDictionary *c = [NSMutableDictionary dictionary];
  for (NSString *k in @[ @"login", @"server", @"role", @"enter", @"battle", @"popup" ]) {
    id arr = ph[k];
    NSUInteger n = [arr isKindOfClass:[NSArray class]] ? [arr count] : 0;
    c[k] = @(n);
  }
  return c;
}

/// 乱码 OCR 时按 y 几何补桶：底→login/enter，中→role，其余 battle
+ (NSDictionary *)criticGeoFillSparsePhases:(NSDictionary *)doc
                                      notes:(NSMutableArray *)notes {
  if (![doc isKindOfClass:[NSDictionary class]])
    return doc;
  NSMutableDictionary *out = [doc mutableCopy];
  NSDictionary *rawPh = [doc[@"phases"] isKindOfClass:[NSDictionary class]]
                            ? doc[@"phases"]
                            : @{};
  NSMutableDictionary *phases =
      [[self rebucketPhases:rawPh] mutableCopy] ?: [NSMutableDictionary dictionary];
  for (NSString *k in @[ @"login", @"server", @"role", @"enter", @"battle", @"popup" ]) {
    if (![phases[k] isKindOfClass:[NSMutableArray class]])
      phases[k] = [NSMutableArray arrayWithArray:
                       [phases[k] isKindOfClass:[NSArray class]] ? phases[k] : @[]];
  }
  NSInteger loginN = [phases[@"login"] count];
  NSInteger roleN = [phases[@"role"] count];
  NSInteger enterN = [phases[@"enter"] count];
  if (loginN > 0 && roleN > 0 && enterN > 0) {
    out[@"phases"] = phases;
    return out;
  }
  NSMutableArray *pool = [NSMutableArray array];
  for (NSString *k in @[ @"battle", @"login", @"role", @"enter", @"server", @"popup" ]) {
    id arr = phases[k];
    if ([arr isKindOfClass:[NSArray class]])
      [pool addObjectsFromArray:arr];
  }
  if ([doc[@"COLOR_PARAMS"] isKindOfClass:[NSArray class]]) {
    for (id it in (NSArray *)doc[@"COLOR_PARAMS"]) {
      if ([it isKindOfClass:[NSDictionary class]])
        [pool addObject:it];
    }
  }
  if (pool.count == 0) {
    [notes addObject:@"geo_skip_empty_pool"];
    out[@"phases"] = phases;
    return out;
  }
  int maxY = 1;
  for (id it in pool) {
    if (![it isKindOfClass:[NSDictionary class]])
      continue;
    int y2 = [it[@"y2"] intValue];
    int y1 = [it[@"y1"] intValue];
    int y = MAX(y1, y2);
    if (y > maxY)
      maxY = y;
  }
  NSMutableArray *login = [phases[@"login"] mutableCopy];
  NSMutableArray *role = [phases[@"role"] mutableCopy];
  NSMutableArray *enter = [phases[@"enter"] mutableCopy];
  NSMutableArray *battle = [phases[@"battle"] mutableCopy];
  NSInteger moved = 0;
  for (id it in pool) {
    if (![it isKindOfClass:[NSDictionary class]])
      continue;
    int y1 = [it[@"y1"] intValue];
    int y2 = [it[@"y2"] intValue];
    double ymid = (MAX(y1, y2) + MIN(y1, y2)) * 0.5;
    double r = ymid / (double)maxY;
    NSMutableDictionary *row = [it mutableCopy];
    if (login.count == 0 && r >= 0.72) {
      row[@"phase"] = @"login";
      row[@"critic"] = @"geo_y_login";
      [login addObject:row];
      moved++;
    } else if (enter.count == 0 && r >= 0.55 && r < 0.85) {
      row[@"phase"] = @"enter";
      row[@"critic"] = @"geo_y_enter";
      [enter addObject:row];
      moved++;
    } else if (role.count == 0 && r >= 0.35 && r < 0.65) {
      row[@"phase"] = @"role";
      row[@"critic"] = @"geo_y_role";
      [role addObject:row];
      moved++;
    } else if (battle.count < 8 && r < 0.55) {
      NSString *ph0 = [row[@"phase"] description] ?: @"";
      if (ph0.length == 0)
        row[@"phase"] = @"battle";
      // 已在 battle 池则跳过重复塞入
      BOOL dup = NO;
      for (id b in battle) {
        if ([b isKindOfClass:[NSDictionary class]] &&
            [b[@"first"] isEqual:row[@"first"]] &&
            [b[@"x1"] isEqual:row[@"x1"]]) {
          dup = YES;
          break;
        }
      }
      if (!dup)
        [battle addObject:row];
    }
    if (login.count > 0 && role.count > 0 && enter.count > 0 && battle.count >= 4)
      break;
  }
  phases[@"login"] = login;
  phases[@"role"] = role;
  phases[@"enter"] = enter;
  phases[@"battle"] = battle;
  out[@"phases"] = phases;
  out[@"critic_geo_moved"] = @(moved);
  [notes addObject:[NSString stringWithFormat:@"geo_fill moved=%ld L=%lu R=%lu E=%lu",
                                              (long)moved, (unsigned long)login.count,
                                              (unsigned long)role.count,
                                              (unsigned long)enter.count]];
  return out;
}

+ (BOOL)phasesSparse:(NSDictionary *)doc {
  NSDictionary *c = [self phaseBucketCounts:doc];
  return [c[@"login"] integerValue] == 0 || [c[@"role"] integerValue] == 0 ||
         [c[@"enter"] integerValue] == 0;
}

+ (NSDictionary *)mergeLive:(NSDictionary *)liveDoc
                      train:(NSDictionary *)trainDoc {
  if (liveDoc && trainDoc) {
    NSMutableDictionary *merged = [liveDoc mutableCopy];
    NSDictionary *lp = liveDoc[@"phases"];
    NSDictionary *tp = trainDoc[@"phases"];
    if ([tp isKindOfClass:[NSDictionary class]]) {
      NSMutableDictionary *phases =
          [tp mutableCopy] ?: [NSMutableDictionary dictionary];
      if ([lp isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in lp) {
          id liveArr = lp[k];
          if ([liveArr isKindOfClass:[NSArray class]] && [liveArr count] > 0) {
            phases[k] = liveArr;
          }
        }
      }
      merged[@"phases"] = phases;
      merged[@"training_merged"] = @YES;
      merged[@"imported"] = @YES;
    }
    return merged;
  }
  return liveDoc ?: trainDoc;
}

+ (nullable NSString *)generateForApp:(ZiYanAppPick *)app
                          resProfile:(NSString *)resProfile
                               error:(NSString **)errOut {
  return [self generateForApp:app
                   resProfile:resProfile
                     progress:nil
                        error:errOut];
}

+ (nullable NSString *)generateForApp:(ZiYanAppPick *)app
                          resProfile:(NSString *)resProfile
                            progress:(ZiYanScriptGenProgress)progress
                               error:(NSString **)errOut {
  void (^prog)(NSString *) = ^(NSString *s) {
    if (progress)
      progress(s);
  };
  if (!app.bundleId.length) {
    if (errOut)
      *errOut = @"missing_bid";
    return nil;
  }
  NSString *family = [self gameFamilyForApp:app];
  NSString *profile = resProfile.length ? resProfile : @"iphone7_13";
  NSDictionary *plan = [self agentPlanForApp:app family:family profile:profile];
  prog(@"[P]规划目标·四阶段");

  NSMutableArray *criticNotes = [NSMutableArray array];
  NSMutableArray *retryReasons = [NSMutableArray array];
  NSInteger visionRounds = 0;
  NSInteger agentRounds = 1;
  NSString *liveErr = nil;
  NSDictionary *liveDoc = nil;
  const NSInteger maxVision = [plan[@"max_vision_rounds"] integerValue] ?: 3;

  // [V] Vision-LiveLearn：空桶则有限回炉再采
  while (visionRounds < maxVision) {
    visionRounds++;
    prog([NSString stringWithFormat:@"[V]识屏取色·第%ld轮", (long)visionRounds]);
    NSString *err = nil;
    NSDictionary *doc =
        [ZiYanLiveVisionLearn learnFromLiveGame:app
                                     resProfile:profile
                                          error:&err];
    if (err.length)
      liveErr = err;
    if (doc) {
      liveDoc = doc;
      liveDoc = [self criticGeoFillSparsePhases:liveDoc notes:criticNotes];
      [ZiYanLiveVisionLearn persistFamilyDoc:liveDoc family:family error:nil];
    }
    BOOL sparse = [self phasesSparse:liveDoc ?: @{}];
    BOOL hasColor = [liveDoc[@"color_count"] integerValue] > 0 ||
                    ([liveDoc[@"COLOR_PARAMS"] isKindOfClass:[NSArray class]] &&
                     [liveDoc[@"COLOR_PARAMS"] count] > 0);
    if (hasColor && !sparse)
      break;
    if (visionRounds >= maxVision)
      break;
    [retryReasons addObject:[NSString stringWithFormat:@"vision_retry_sparse_r%ld",
                                                       (long)visionRounds]];
    prog(@"[Critic]空桶·等待画面再采");
    [NSThread sleepForTimeInterval:2.2];
  }
  if (!liveDoc) {
    [criticNotes addObject:@"live_doc_nil"];
    [retryReasons addObject:@"live_miss_use_knowledge"];
  }

  // [K] Knowledge merge
  prog(@"[K]合并训练逻辑");
  NSDictionary *trainDoc = [self loadFamilyDoc:family];
  NSDictionary *doc = [self mergeLive:liveDoc train:trainDoc];
  if (doc) {
    NSMutableArray *n2 = [NSMutableArray array];
    doc = [self criticGeoFillSparsePhases:doc notes:n2];
    [criticNotes addObjectsFromArray:n2];
  }

  // [G] Codegen A→B→C
  prog(@"[G]侧车A→Codegen→B→C");
  NSString *status = nil;
  BOOL modelsOk = [ZiYanLLMSidecarClient modelsReadyWant:3 statusOut:&status];
  NSDictionary *bucketCounts = [self phaseBucketCounts:doc ?: @{}];
  NSDictionary *req = @{
    @"app_name" : app.displayName ?: @"",
    @"bid" : app.bundleId,
    @"bundle_path" : app.bundlePath ?: @"",
    @"res_profile" : profile,
    @"game_family" : family,
    @"endpoint" : @"/v1/scriptgen/run",
    @"knowledge_imported" : @([doc[@"imported"] boolValue]),
    @"live_vision" : @([doc[@"live_vision"] boolValue]),
    @"live_color_count" : @([doc[@"color_count"] integerValue]),
    @"training_merged" : @([doc[@"training_merged"] boolValue]),
    @"phase_bucket_counts" : bucketCounts ?: @{},
    @"agent_plan" : plan ?: @{},
    @"training_hints" : @[
      @"full_business", @"phase_login", @"phase_role_select",
      @"phase_enter_game", @"phase_auto_battle", @"Ai代码训练", @"no_TSLib",
      @"live_ocr_color", @"no_manual_color_pick",
      @"fill_colors_into_findMultiColor", @"fable_local_agent"
    ],
    @"models_ready" : @(modelsOk),
  };
  NSString *scErr = nil;
  NSDictionary *result =
      [ZiYanLLMSidecarClient runScriptGen:req timeoutSec:25.0 error:&scErr];
  NSString *lua = nil;
  NSString *audit = nil;
  BOOL fromSidecar = NO;
  BOOL fromKnowledge = NO;
  BOOL modelsCombined = NO;

  if ([result[@"ok"] boolValue] &&
      [result[@"lua"] isKindOfClass:[NSString class]] &&
      [result[@"lua"] length] > 64 &&
      [result[@"lua"] containsString:@"phase_login"] &&
      [result[@"lua"] containsString:@"phase_auto_battle"] &&
      [result[@"lua"] containsString:@"runApp("] &&
      ![result[@"lua"] containsString:@"TSLib"]) {
    lua = result[@"lua"];
    audit = [result[@"audit_id"] description];
    fromSidecar = YES;
    modelsCombined = [result[@"models_combined"] boolValue] ||
                     [result[@"models"] isKindOfClass:[NSDictionary class]];
    fromKnowledge = [doc[@"imported"] boolValue] ||
                    [result[@"knowledge_imported"] boolValue];
  } else if ([doc[@"imported"] boolValue]) {
    lua = [self fullBusinessLuaForApp:app
                           resProfile:profile
                           gameFamily:family
                                  doc:doc];
    fromKnowledge = YES;
    audit = @"knowledge_fallback_need_sidecar";
    [retryReasons addObject:@"sidecar_miss_knowledge_lua"];
  } else {
    lua = [self fullBusinessLuaForApp:app
                           resProfile:profile
                           gameFamily:family
                                  doc:doc ?: @{}];
    if (errOut) {
      *errOut = scErr ?: @"training_full_lua_no_sidecar";
    }
    [retryReasons addObject:@"no_import_full_lua"];
  }

  BOOL flowOk = [lua containsString:@"runApp("] &&
                [lua containsString:@"phase_login"] &&
                [lua containsString:@"phase_role_select"] &&
                [lua containsString:@"phase_enter_game"] &&
                [lua containsString:@"phase_auto_battle"];
  if (!flowOk) {
    lua = [self fullBusinessLuaForApp:app
                           resProfile:profile
                           gameFamily:family
                                  doc:doc ?: @{}];
    audit = [NSString stringWithFormat:@"%@|regen_full_flow", audit ?: @"regen"];
    flowOk = YES;
    [retryReasons addObject:@"regen_full_flow"];
  }

  NSDictionary *models = [result[@"models"] isKindOfClass:[NSDictionary class]]
                             ? result[@"models"]
                             : @{
                                 @"prompt_guard" : @{@"id" : @"A", @"ok" : @NO, @"label" : @"sidecar_miss"},
                                 @"vincentoh" : @{@"id" : @"B", @"ok" : @NO, @"label" : @"sidecar_miss"},
                                 @"mmbert" : @{@"id" : @"C", @"ok" : @NO, @"label" : @"sidecar_miss"},
                               };
  if ([result[@"models_combined"] boolValue]) {
    modelsCombined = YES;
  } else if ([models[@"prompt_guard"] isKindOfClass:[NSDictionary class]] &&
             [models[@"vincentoh"] isKindOfClass:[NSDictionary class]] &&
             [models[@"mmbert"] isKindOfClass:[NSDictionary class]]) {
    modelsCombined = [models[@"prompt_guard"][@"ok"] boolValue] &&
                     [models[@"vincentoh"][@"ok"] boolValue] &&
                     [models[@"mmbert"][@"ok"] boolValue];
  }

  NSString *base = [self sanitizeFileBase:app.displayName];
  NSString *stripped =
      [base stringByReplacingOccurrencesOfString:@"_" withString:@""];
  if (stripped.length == 0) {
    base = [self sanitizeFileBase:[app.bundleId
                                      stringByReplacingOccurrencesOfString:@"."
                                                                withString:@"_"]];
  }
  stripped = [base stringByReplacingOccurrencesOfString:@"_" withString:@""];
  if (stripped.length == 0)
    base = @"gen_app";
  NSString *path = [ZiYanScriptsDirectory()
      stringByAppendingPathComponent:[base stringByAppendingString:@".lua"]];
  NSError *we = nil;
  if (![lua writeToFile:path
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:&we]) {
    if (errOut)
      *errOut = we.localizedDescription ?: @"write_lua_fail";
    return nil;
  }
  chmod(path.fileSystemRepresentation, 0644);

  {
    NSString *kb = [[self knowledgeRoot] stringByAppendingPathComponent:@"KB.jsonl"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[self knowledgeRoot]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *line = [NSString
        stringWithFormat:
            @"{\"ts\":%ld,\"event\":\"scriptgen_agent\",\"family\":\"%@\",\"bid\":\"%@\","
             @"\"path\":\"%@\",\"vision_rounds\":%ld,\"from_knowledge\":%@,\"ok\":true}\n",
            (long)time(NULL), family, app.bundleId, path, (long)visionRounds,
            fromKnowledge ? @"true" : @"false"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kb];
    if (!fh) {
      [line writeToFile:kb atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
      [fh seekToEndOfFile];
      [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    }
  }

  NSString *retryJoined =
      retryReasons.count ? [retryReasons componentsJoinedByString:@","] : @"";
  NSDictionary *mark = @{
    @"path" : path,
    @"bid" : app.bundleId,
    @"game_family" : family,
    @"audit_id" : audit ?: @"full_business_r8411",
    @"from_sidecar" : @(fromSidecar),
    @"from_knowledge" : @(fromKnowledge),
    @"models_ready" : @(modelsOk),
    @"models_combined" : @(modelsCombined),
    @"pipeline" : @"Agent[P→V→K→G→T]",
    @"agent_rounds" : @(agentRounds),
    @"vision_rounds" : @(visionRounds),
    @"retry_reason" : retryJoined.length ? retryJoined : [NSNull null],
    @"plan" : plan ?: @{},
    @"phase_bucket_counts" : bucketCounts ?: @{},
    @"critic_notes" : criticNotes.count ? criticNotes : @[],
    @"live_vision" : @([doc[@"live_vision"] boolValue]),
    @"live_color_count" : doc[@"color_count"] ?: @0,
    @"live_err" : liveErr ?: [NSNull null],
    @"models" : models ?: [NSNull null],
    @"has_runApp" : @([lua containsString:@"runApp("]),
    @"has_phase_login" : @([lua containsString:@"phase_login"]),
    @"has_phase_role" : @([lua containsString:@"phase_role_select"]),
    @"has_phase_enter" : @([lua containsString:@"phase_enter_game"]),
    @"has_phase_battle" : @([lua containsString:@"phase_auto_battle"]),
    @"flow_ok" : @(flowOk),
    @"endpoint" : @"/v1/scriptgen/run",
    @"sidecar_error" : scErr ?: [NSNull null],
    @"paid_api" : @NO,
  };
  NSData *md = [NSJSONSerialization dataWithJSONObject:mark options:0 error:nil];
  [md writeToFile:[ZiYanScriptsDirectory()
                      stringByAppendingPathComponent:@".scriptgen_last.json"]
       atomically:YES];
  prog(@"[G]落盘完成·交[T]自测");
  return path;
}

@end
