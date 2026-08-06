#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZiYanPaths.h"

/*
 * ZiYanMemHook — 注入游戏进程，被动捕获 JSON/UI 中的角色/排行/背包数据。
 * IPC：.ziyan_mem_req → .ziyan_mem_rep；快照：memory/hook_snapshot.json
 */

@interface ZiYanMemHook : NSObject
+ (void)start;
@end

static NSMutableDictionary *gRole;   // name / att / level
static NSMutableArray *gRank;        // @{rank,name,guild}
static NSMutableArray *gBag;         // item name strings
static NSMutableSet *gBagSeen;
static NSMutableSet *gRankSeen;
static NSTimeInterval gSnapTS;
static dispatch_source_t gPollTimer;
static NSTimeInterval gLastReqStamp;
static NSLock *gLock;

static BOOL ZYLooksCN(NSString *s, NSUInteger minLen, NSUInteger maxLen) {
  if (![s isKindOfClass:[NSString class]]) return NO;
  NSUInteger n = s.length;
  if (n < minLen || n > maxLen) return NO;
  NSUInteger cjk = 0;
  for (NSUInteger i = 0; i < n; i++) {
    unichar c = [s characterAtIndex:i];
    if (c >= 0x4E00 && c <= 0x9FFF) cjk++;
  }
  return cjk >= MIN(minLen, (NSUInteger)2);
}

static BOOL ZYIsUINoise(NSString *s) {
  static NSArray *bad;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    bad = @[
      @"确认", @"取消", @"关闭", @"返回", @"购买", @"出售", @"使用", @"穿戴",
      @"排行榜", @"角色", @"背包", @"属性", @"状态", @"装备", @"技能", @"称号",
      @"登录", @"公告", @"通知", @"规则", @"声明", @"提示", @"场景", @"成功",
      @"失败", @"解封", @"合服", @"更新", @"版本", @"账号", @"区服", @"列表",
      @"我的排名", @"未上榜", @"所属行会", @"查看", @"职业", @"等级", @"经验",
      @"请输入", @"密码", @"手机", @"验证码", @"用户协议", @"客服", @"绑定",
      @"福利", @"分享", @"小号", @"管理", @"服务", @"年前", @"月前", @"天前",
      @"传奇", @"血战", @"屠龙", @"获取", @"联系", @"我的", @"你的", @"他的",
      @"点击", @"进入", @"开始", @"选择", @"服务器", @"渠道",
    ];
  });
  for (NSString *b in bad) {
    if ([s isEqualToString:b] || [s containsString:b]) return YES;
  }
  return NO;
}

static BOOL ZYLooksPlayerName(NSString *s) {
  if (!ZYLooksCN(s, 3, 8) || ZYIsUINoise(s)) return NO; // 至少 3 字
  NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
  for (NSUInteger i = 0; i < s.length; i++) {
    if ([digits characterIsMember:[s characterAtIndex:i]]) return NO;
  }
  if ([s containsString:@"前"] || [s containsString:@"后"]) return NO;
  return YES;
}

static BOOL ZYLooksItem(NSString *s) {
  if (!ZYLooksCN(s, 2, 24) || ZYIsUINoise(s)) return NO;
  static NSArray *keys;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    keys = @[
      @"剑", @"甲", @"戒", @"腰带", @"盔", @"靴", @"石", @"丹", @"卷", @"珠",
      @"符", @"刃", @"刀", @"杖", @"衣", @"袍", @"链", @"环", @"勋章", @"材料",
      @"礼包", @"箱子", @"令", @"结晶", @"铠", @"腕", @"带", @"帽", @"金刚石"
    ];
  });
  for (NSString *k in keys) {
    if ([s containsString:k]) return YES;
  }
  return s.length >= 4;
}

static NSString *ZYStr(id v) {
  if ([v isKindOfClass:[NSString class]]) return [(NSString *)v copy];
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
  return nil;
}

static void ZYPersistSnapshot(void) {
  ZiYanEnsureVarDirectory();
  NSString *dir = [ZiYanVarDirectory() stringByAppendingPathComponent:@"memory"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSDictionary *snap;
  [gLock lock];
  snap = @{
    @"ok" : @YES,
    @"ts" : @(gSnapTS),
    @"role" : [gRole copy] ?: @{},
    @"rank" : [gRank copy] ?: @[],
    @"bag" : [gBag copy] ?: @[],
  };
  [gLock unlock];
  NSData *data =
      [NSJSONSerialization dataWithJSONObject:snap options:0 error:nil];
  if (data) {
    [data writeToFile:[dir stringByAppendingPathComponent:@"hook_snapshot.json"]
           atomically:YES];
  }
}

static void ZYTouchSnap(void) {
  gSnapTS = [[NSDate date] timeIntervalSince1970];
  ZYPersistSnapshot();
}

static void ZYIngestRoleKey(NSString *key, NSString *val) {
  if (!key.length || !val.length) return;
  NSString *k = key.lowercaseString;
  [gLock lock];
  if ([k containsString:@"rolename"] || [k isEqualToString:@"name"] ||
      [k isEqualToString:@"nickname"] || [k isEqualToString:@"charname"]) {
    if (ZYLooksPlayerName(val)) {
      gRole[@"name"] = val;
    }
  } else if ([k containsString:@"roleatt"] || [k isEqualToString:@"att"] ||
             [k isEqualToString:@"attack"] ||
             [k containsString:@"physicalatt"]) {
    if (val.length <= 16) gRole[@"att"] = val;
  } else if ([k containsString:@"rolelevel"] || [k isEqualToString:@"level"] ||
             [k containsString:@"relevel"] || [k containsString:@"turnlevel"]) {
    // 只收数字等级，避免 UI「等级」文案
    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([val rangeOfCharacterFromSet:nonDigit].location == NSNotFound &&
        val.length <= 8) {
      gRole[@"level"] = val;
    }
  } else if ([k containsString:@"relive"] || [k containsString:@"reborn"] ||
             [k containsString:@"zhuansheng"]) {
    if (val.length <= 8) gRole[@"relive"] = val;
  }
  [gLock unlock];
  ZYTouchSnap();
}

static void ZYAddRank(NSString *name, NSString *guild, NSInteger rank) {
  if (!ZYLooksPlayerName(name) &&
      !([name containsString:@"丿"] || [name containsString:@"戰"]))
    return;
  if (ZYIsUINoise(name)) return;
  [gLock lock];
  NSString *key = name;
  if ([gRankSeen containsObject:key]) {
    [gLock unlock];
    return;
  }
  [gRankSeen addObject:key];
  NSMutableDictionary *row = [@{@"name" : name} mutableCopy];
  if (guild.length && !ZYIsUINoise(guild)) row[@"guild"] = guild;
  if (rank > 0) row[@"rank"] = @(rank);
  [gRank addObject:row];
  if (gRank.count > 80) {
    [gRank removeObjectsInRange:NSMakeRange(0, gRank.count - 80)];
  }
  [gLock unlock];
  ZYTouchSnap();
}

static void ZYAddBag(NSString *item) {
  if (!ZYLooksItem(item)) return;
  [gLock lock];
  if ([gBagSeen containsObject:item]) {
    [gLock unlock];
    return;
  }
  [gBagSeen addObject:item];
  [gBag addObject:item];
  if (gBag.count > 200) {
    NSString *old = gBag[0];
    [gBag removeObjectAtIndex:0];
    [gBagSeen removeObject:old];
  }
  [gLock unlock];
  ZYTouchSnap();
}

static void ZYWalkJSON(id obj, NSInteger depth);

static void ZYWalkDict(NSDictionary *dict, NSInteger depth) {
  if (depth > 8 || ![dict isKindOfClass:[NSDictionary class]]) return;

  // 角色字段
  for (NSString *key in
       @[ @"roleName", @"RoleName", @"roleAtt", @"roleLevel", @"roleRelive",
          @"turnLevel", @"relevel", @"name", @"guild", @"guildName", @"GuildName",
          @"itemName", @"ItemName", @"rank", @"Rank" ]) {
    id v = dict[key];
    NSString *s = ZYStr(v);
    if (!s.length) continue;
    if ([key.lowercaseString containsString:@"guild"]) {
      // guild alone — pair later with name in same dict
    } else if ([key.lowercaseString containsString:@"item"]) {
      ZYAddBag(s);
    } else {
      ZYIngestRoleKey(key, s);
    }
  }

  NSString *name = ZYStr(dict[@"name"] ?: dict[@"userName"] ?: dict[@"roleName"] ?:
                         dict[@"RoleName"] ?: dict[@"nickName"]);
  NSString *guild = ZYStr(dict[@"guild"] ?: dict[@"guildName"] ?:
                          dict[@"GuildName"] ?: dict[@"unionName"]);
  NSInteger rank = [dict[@"rank"] integerValue];
  if (!rank) rank = [dict[@"Rank"] integerValue];
  if (name.length && (guild.length || rank > 0 ||
                      [name containsString:@"戰"] || [name containsString:@"丿"])) {
    ZYAddRank(name, guild ?: @"", rank);
  }
  if (name.length && ZYLooksItem(name) && !guild.length) {
    ZYAddBag(name);
  }

  // 数组字段：rankList / bag / items
  for (NSString *ak in dict) {
    id av = dict[ak];
    NSString *lk = ak.lowercaseString;
    if ([av isKindOfClass:[NSArray class]]) {
      if ([lk containsString:@"rank"] || [lk containsString:@"top"] ||
          [lk containsString:@"list"]) {
        for (id it in (NSArray *)av) {
          ZYWalkJSON(it, depth + 1);
        }
      } else if ([lk containsString:@"bag"] || [lk containsString:@"item"] ||
                 [lk containsString:@"goods"] || [lk containsString:@"pack"]) {
        for (id it in (NSArray *)av) {
          if ([it isKindOfClass:[NSString class]]) {
            ZYAddBag((NSString *)it);
          } else {
            ZYWalkJSON(it, depth + 1);
          }
        }
      } else if (depth < 3) {
        for (id it in (NSArray *)av) {
          ZYWalkJSON(it, depth + 1);
        }
      }
    } else if ([av isKindOfClass:[NSDictionary class]] && depth < 5) {
      ZYWalkJSON(av, depth + 1);
    } else if ([av isKindOfClass:[NSString class]] ||
               [av isKindOfClass:[NSNumber class]]) {
      ZYIngestRoleKey(ak, ZYStr(av));
      if ([lk containsString:@"item"] || [lk containsString:@"goods"]) {
        ZYAddBag(ZYStr(av));
      }
    }
  }
}

static void ZYWalkJSON(id obj, NSInteger depth) {
  if (!obj || depth > 8) return;
  if ([obj isKindOfClass:[NSDictionary class]]) {
    ZYWalkDict((NSDictionary *)obj, depth);
  } else if ([obj isKindOfClass:[NSArray class]]) {
    for (id it in (NSArray *)obj) {
      ZYWalkJSON(it, depth + 1);
    }
  }
}

#pragma mark - Method hooks

static id (*ZYOrigJSONObjectWithData)(id, SEL, NSData *, NSUInteger, NSError **);
static id ZYHookJSONObjectWithData(id self, SEL _cmd, NSData *data,
                                   NSUInteger opt, NSError **err) {
  id obj = ZYOrigJSONObjectWithData(self, _cmd, data, opt, err);
  if (obj) {
    @try {
      ZYWalkJSON(obj, 0);
    } @catch (__unused NSException *ex) {
    }
  }
  return obj;
}

static void ZYIngestUIText(NSString *text) {
  if (![text isKindOfClass:[NSString class]] || text.length < 2) return;
  @try {
    NSString *t = [text
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (ZYIsUINoise(t)) return;
    if ([t containsString:@"转"] && [t containsString:@"级"] && t.length <= 16) {
      [gLock lock];
      gRole[@"levelText"] = t;
      [gLock unlock];
      ZYTouchSnap();
      return;
    }
    // UILabel 不写角色名（登录/HUD 噪音太多）；等级文案与排行/物品仍收
    if ([t containsString:@"丿"] ||
        ([t containsString:@"戰"] && t.length >= 4 && t.length <= 14)) {
      ZYAddRank(t, @"", 0);
    }
    if (ZYLooksItem(t)) {
      ZYAddBag(t);
    }
  } @catch (__unused NSException *ex) {
  }
}

static void (*ZYOrigLabelSetText)(id, SEL, NSString *);
static void ZYHookLabelSetText(id self, SEL _cmd, NSString *text) {
  ZYOrigLabelSetText(self, _cmd, text);
  ZYIngestUIText(text);
}

static void (*ZYOrigLabelSetAttr)(id, SEL, NSAttributedString *);
static void ZYHookLabelSetAttr(id self, SEL _cmd, NSAttributedString *attr) {
  ZYOrigLabelSetAttr(self, _cmd, attr);
  ZYIngestUIText(attr.string);
}

/* unused helper removed — swizzle done inline in +start */
static NSArray *ZYBuildTexts(NSString *mode) {
  NSMutableArray *texts = [NSMutableArray array];
  [gLock lock];
  if ([mode isEqualToString:@"角色"] || [mode isEqualToString:@"character"] ||
      [mode isEqualToString:@"role"]) {
    NSString *name = gRole[@"name"] ?: @"";
    NSString *att = gRole[@"att"] ?: @"";
    NSString *lv = gRole[@"level"] ?: @"";
    NSString *relive = gRole[@"relive"] ?: @"";
    NSString *levelText = gRole[@"levelText"] ?: @"";
    if (!levelText.length) {
      if (relive.length && lv.length)
        levelText = [NSString stringWithFormat:@"%@转%@级", relive, lv];
      else if (lv.length)
        levelText = [NSString stringWithFormat:@"%@级", lv];
    }
    if (name.length)
      [texts addObject:[NSString stringWithFormat:@"名称:%@", name]];
    if (att.length)
      [texts addObject:[NSString stringWithFormat:@"攻击:%@", att]];
    if (levelText.length)
      [texts addObject:[NSString stringWithFormat:@"等级:%@", levelText]];
  } else if ([mode isEqualToString:@"排行榜"] || [mode isEqualToString:@"rank"] ||
             [mode isEqualToString:@"leaderboard"]) {
    NSInteger i = 1;
    for (NSDictionary *row in gRank) {
      NSString *name = row[@"name"] ?: @"";
      NSString *guild = row[@"guild"] ?: @"-";
      NSInteger rk = [row[@"rank"] integerValue];
      if (rk <= 0) rk = i;
      [texts addObject:[NSString stringWithFormat:@"%ld|%@|%@", (long)rk, name,
                                                  guild.length ? guild : @"-"]];
      i++;
      if (i > 40) break;
    }
  } else if ([mode isEqualToString:@"背包"] || [mode isEqualToString:@"bag"] ||
             [mode isEqualToString:@"backpack"]) {
    for (NSString *it in gBag) {
      [texts addObject:it];
      if (texts.count >= 80) break;
    }
  }
  [gLock unlock];
  return texts;
}

static NSString *ZYJSONEscape(NSString *s) {
  if (!s) return @"";
  NSMutableString *o = [s mutableCopy];
  NSArray *pairs = @[
    @[ @"\\", @"\\\\" ], @[ @"\"", @"\\\"" ], @[ @"\n", @"\\n" ],
    @[ @"\r", @"\\r" ], @[ @"\t", @"\\t" ]
  ];
  for (NSArray *p in pairs) {
    [o replaceOccurrencesOfString:p[0]
                       withString:p[1]
                          options:0
                            range:NSMakeRange(0, o.length)];
  }
  return o;
}

static void ZYWriteRep(NSString *nonce, NSString *mode, NSArray *texts) {
  NSMutableString *arr = [NSMutableString stringWithString:@"["];
  for (NSUInteger i = 0; i < texts.count; i++) {
    if (i) [arr appendString:@","];
    [arr appendFormat:@"\"%@\"", ZYJSONEscape(texts[i])];
  }
  [arr appendString:@"]"];
  NSString *json = [NSString
      stringWithFormat:
          @"{\"ok\":%s,\"nonce\":\"%@\",\"mode\":\"%@\",\"texts\":%@,\"count\":%lu,"
          @"\"via\":\"hook\"}\n",
          texts.count ? "true" : "false", ZYJSONEscape(nonce ?: @""),
          ZYJSONEscape(mode ?: @""), arr, (unsigned long)texts.count];
  [json writeToFile:ZiYanVarFile(@".ziyan_mem_rep")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

static void ZYPollReq(void) {
  NSString *path = ZiYanVarFile(@".ziyan_mem_req");
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  NSTimeInterval stamp = mod ? mod.timeIntervalSince1970 : 0;
  if (stamp <= 0 || stamp <= gLastReqStamp + 0.001) return;
  gLastReqStamp = stamp;

  NSData *raw = [NSData dataWithContentsOfFile:path];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  if (!raw.length) return;
  NSDictionary *req =
      [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
  if (![req isKindOfClass:[NSDictionary class]]) return;
  NSString *op = [NSString stringWithFormat:@"%@", req[@"op"] ?: req[@"mode"] ?: @""];
  NSString *nonce = [NSString stringWithFormat:@"%@", req[@"nonce"] ?: @"0"];
  NSArray *texts = ZYBuildTexts(op);
  ZYWriteRep(nonce, op, texts);
}

@implementation ZiYanMemHook

+ (void)start {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gLock = [[NSLock alloc] init];
    gRole = [NSMutableDictionary dictionary];
    gRank = [NSMutableArray array];
    gBag = [NSMutableArray array];
    gBagSeen = [NSMutableSet set];
    gRankSeen = [NSMutableSet set];
    ZiYanEnsureVarDirectory();

    Class jsonCls = objc_getClass("NSJSONSerialization");
    if (jsonCls) {
      Method m = class_getClassMethod(
          jsonCls, @selector(JSONObjectWithData:options:error:));
      if (m) {
        ZYOrigJSONObjectWithData =
            (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)ZYHookJSONObjectWithData);
      }
    }

    Class labelCls = objc_getClass("UILabel");
    if (labelCls) {
      Method m1 = class_getInstanceMethod(labelCls, @selector(setText:));
      if (m1) {
        ZYOrigLabelSetText = (void *)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)ZYHookLabelSetText);
      }
      Method m2 =
          class_getInstanceMethod(labelCls, @selector(setAttributedText:));
      if (m2) {
        ZYOrigLabelSetAttr = (void *)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)ZYHookLabelSetAttr);
      }
    }

    dispatch_queue_t q =
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    gPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(gPollTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.05 * NSEC_PER_SEC),
                              (uint64_t)(0.02 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gPollTimer, ^{
      ZYPollReq();
    });
    dispatch_resume(gPollTimer);

    // 心跳：hook 已启动
    [@"1" writeToFile:ZiYanVarFile(@".ziyan_mem_hook_alive")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    NSLog(@"[ZiYanMemHook] started");
  });
}

@end
