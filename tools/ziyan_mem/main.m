#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * ziyan_mem — 进程内存字符串扫描（越狱机 task_for_pid）
 *
 *   ziyan_mem find <pid> <text> [--near BYTES] [--json]
 *   ziyan_mem scan <pid> [--cn] [--min N] [--max N] [--limit N] [--json]
 *   ziyan_mem role <pid> [--limit N] [--json]
 */

static NSString *JSONEscape(NSString *s) {
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

static BOOL IsCJKLead(uint8_t c) {
  return (c & 0xF0) == 0xE0 && c >= 0xE4 && c <= 0xE9;
}

static BOOL LooksLikeCNName(const uint8_t *p, size_t len, size_t *outChars) {
  if (len < 6 || len > 24) return NO;
  size_t i = 0;
  size_t chars = 0;
  size_t cjk = 0;
  while (i < len) {
    uint8_t c = p[i];
    if (c < 0x80) {
      return NO;
    } else if ((c & 0xF0) == 0xE0 && i + 2 < len) {
      if (c >= 0xE4 && c <= 0xE9) cjk++;
      i += 3;
      chars++;
    } else {
      return NO;
    }
    if (chars > 8) return NO;
  }
  if (chars < 2 || chars > 8) return NO;
  if (cjk < 2) return NO;
  if (outChars) *outChars = chars;
  return YES;
}

/* 边界：前一字节非 CJK 续字节，后一字节非 CJK 起始 */
static BOOL HasCNBoundary(const uint8_t *buf, size_t n, size_t i, size_t need) {
  if (i > 0) {
    uint8_t prev = buf[i - 1];
    // UTF-8 续字节 10xxxxxx，或上一字符是 CJK 三字节的一部分
    if ((prev & 0xC0) == 0x80) return NO;
    if (IsCJKLead(prev)) return NO;
  }
  if (i + need < n) {
    uint8_t next = buf[i + need];
    if (IsCJKLead(next)) return NO;
  }
  return YES;
}

static BOOL ShouldSkipName(NSString *s) {
  static NSArray *bad;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    bad = @[
      @"十八地狱", @"经验", @"等级", @"职业", @"装备", @"属性", @"技能",
      @"称号", @"状态", @"当前", @"升级", @"任务", @"组队", @"战士",
      @"暗黑主宰", @"亿", @"万", @"战力", @"物理", @"攻击", @"防御",
      @"生命", @"魔法", @"暴击", @"吸血", @"增伤", @"爆率", @"倍数",
      @"物品", @"说明", @"使用", @"获取", @"途径", @"活动", @"战场",
      @"玩家", @"准备", @"传送", @"复活", @"淘汰", @"积分", @"击杀",
      @"背包", @"道具", @"地图", @"空投", @"毒圈", @"英雄", @"按钮",
      @"背景", @"队员", @"行会", @"官方", @"社区", @"永久", @"专属",
      @"基础", @"加成", @"抗性", @"解锁", @"计时", @"持续", @"时间",
      @"每日", @"开启", @"进入", @"随机", @"安全", @"全体", @"模式",
      @"禁用", @"获得", @"死亡", @"扣除", @"存活", @"压缩", @"穿戴",
      @"提高", @"刷新", @"大量", @"拾取", @"坐骑", @"投放", @"造成",
      @"每隔", @"缩圈", @"点击", @"切换", @"内容", @"伸缩", @"组合",
      @"冠名", @"推选", @"传说", @"远古", @"魔神", @"本期", @"分钟",
      @"封神", @"斩将", @"百战", @"登仙", @"伏魔", @"麻痹", @"特戒",
      @"昆仑", @"玲珑", @"吃鸡", @"孤高", @"道行", @"天尊", @"联赛",
      @"八卦", @"降妖", @"上古", @"神器", @"仙装", @"龙纹", @"大陆",
      @"仙府", @"化身", @"灵根", @"炼气", @"锻体", @"元神", @"头盔",
      @"护符", @"腰带", @"肩甲", @"项链", @"勋章", @"靴子", @"戒指",
      @"仙界", @"神装", @"命格", @"降魔", @"西周", @"古城", @"狂潮",
      @"蛮荒", @"刑天", @"西岐", @"边境", @"神农", @"宝库", @"福利",
      @"神王", @"反吟", @"星君", @"元宝", @"商店", @"合成", @"对应",
      @"摇光", @"仙境", @"九曜", @"火焰", @"狂狮", @"正神", @"刀砧",
      @"蚩尤", @"深渊", @"骷髅", @"云海", @"扶桑", @"神树", @"叔琨",
      @"激活", @"奖励", @"幻境", @"主宰", @"托塔", @"天王", @"申公",
      @"公豹", @"昊天", @"大帝", @"镜像", @"爆率", @"他们", @"你们",
    ];
  });
  for (NSString *b in bad) {
    if ([s containsString:b]) return YES;
  }
  return NO;
}

static BOOL IsSubstringOfAny(NSString *s, NSArray *arr) {
  for (NSString *t in arr) {
    if (t.length > s.length && [t containsString:s]) return YES;
  }
  return NO;
}

static void CollectCNNear(const uint8_t *buf, size_t n, size_t center,
                          size_t near, NSMutableArray *texts,
                          NSMutableSet *seen, NSUInteger maxTexts) {
  if (!buf || n == 0 || near == 0 || !texts) return;
  if (texts.count >= maxTexts) return;
  size_t start = center > near ? center - near : 0;
  size_t end = center + near;
  if (end > n) end = n;
  for (size_t i = start; i + 6 <= end; i++) {
    if (texts.count >= maxTexts) break;
    if (!IsCJKLead(buf[i])) continue;
    // 优先更长串，减少「君魔」「魔仙」这类碎片
    for (size_t chars = 6; chars >= 2; chars--) {
      size_t need = chars * 3;
      if (i + need > end) continue;
      size_t got = 0;
      if (!LooksLikeCNName(buf + i, need, &got)) continue;
      if (!HasCNBoundary(buf, n, i, need)) continue;
      NSString *s = [[NSString alloc] initWithBytes:buf + i
                                             length:need
                                           encoding:NSUTF8StringEncoding];
      if (!s.length || [seen containsObject:s] || ShouldSkipName(s)) continue;
      if (IsSubstringOfAny(s, texts)) continue;
      [seen addObject:s];
      [texts addObject:s];
      break;
    }
  }
}

static NSMutableArray *ScanRegions(task_t task, NSData *needle, BOOL scanCN,
                                   NSInteger minC, NSInteger maxC,
                                   NSInteger limit, size_t nearBytes,
                                   NSMutableArray *outTexts) {
  NSMutableArray *hits = [NSMutableArray array];
  NSMutableSet *seenHit = [NSMutableSet set];
  NSMutableSet *seenText = [NSMutableSet set];
  NSUInteger maxNear = 24;

  vm_address_t address = 0;
  vm_size_t size = 0;
  natural_t depth = 0;

  while ((NSInteger)hits.count < limit) {
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t kr = vm_region_recurse_64(
        task, &address, &size, &depth, (vm_region_recurse_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
      break;
    }
    if (info.is_submap) {
      depth++;
      continue;
    }

    BOOL readable = (info.protection & VM_PROT_READ) != 0;
    if (readable && size > 0 && size <= (32u * 1024u * 1024u)) {
      vm_offset_t data = 0;
      mach_msg_type_number_t dataCnt = 0;
      kr = vm_read(task, address, size, &data, &dataCnt);
      if (kr == KERN_SUCCESS && data && dataCnt > 0) {
        const uint8_t *buf = (const uint8_t *)(uintptr_t)data;
        size_t n = (size_t)dataCnt;

        if (needle.length > 0) {
          const uint8_t *nd = needle.bytes;
          size_t nl = needle.length;
          if (nl > 0 && n >= nl) {
            for (size_t i = 0; i + nl <= n && hits.count < (NSUInteger)limit; i++) {
              if (memcmp(buf + i, nd, nl) == 0) {
                NSString *s =
                    [[NSString alloc] initWithBytes:nd
                                             length:nl
                                           encoding:NSUTF8StringEncoding];
                if (s.length) {
                  NSString *addr = [NSString
                      stringWithFormat:@"0x%lx", (unsigned long)(address + i)];
                  [hits addObject:@{@"text" : s, @"address" : addr}];
                  if (outTexts && ![seenText containsObject:s]) {
                    [seenText addObject:s];
                    [outTexts addObject:s];
                  }
                  if (outTexts && nearBytes > 0) {
                    CollectCNNear(buf, n, i, nearBytes, outTexts, seenText,
                                  maxNear);
                  }
                }
                i += nl - 1;
              }
            }
          }
        } else if (scanCN) {
          for (size_t i = 0; i + 6 <= n && hits.count < (NSUInteger)limit; i++) {
            if (!IsCJKLead(buf[i])) continue;
            for (size_t chars = (size_t)maxC; chars >= (size_t)minC; chars--) {
              size_t need = chars * 3;
              if (i + need > n) continue;
              size_t got = 0;
              if (!LooksLikeCNName(buf + i, need, &got)) continue;
              if ((NSInteger)got < minC || (NSInteger)got > maxC) continue;
              if (!HasCNBoundary(buf, n, i, need)) continue;
              NSString *s =
                  [[NSString alloc] initWithBytes:buf + i
                                           length:need
                                         encoding:NSUTF8StringEncoding];
              if (!s.length || [seenHit containsObject:s] || ShouldSkipName(s)) {
                continue;
              }
              [seenHit addObject:s];
              NSString *addr = [NSString
                  stringWithFormat:@"0x%lx", (unsigned long)(address + i)];
              [hits addObject:@{@"text" : s, @"address" : addr}];
              break;
            }
          }
        }
        vm_deallocate(mach_task_self(), data, dataCnt);
      }
    }
    address += size;
  }
  return hits;
}

/* 是否像 JSON/转义字符串里的 "名字" 或 \"名字\" */
static BOOL IsQuotedCN(const uint8_t *buf, size_t n, size_t i, size_t need) {
  if (need == 0 || i + need > n) return NO;
  BOOL prevQuote = NO;
  if (i >= 1 && buf[i - 1] == '"') prevQuote = YES;
  if (i >= 2 && buf[i - 2] == '\\' && buf[i - 1] == '"') prevQuote = YES;
  if (!prevQuote) return NO;
  // 结尾: "  或  \"  或  ",
  if (i + need < n && buf[i + need] == '"') return YES;
  if (i + need + 1 < n && buf[i + need] == '\\' && buf[i + need + 1] == '"')
    return YES;
  return NO;
}

/* 角色名候选：JSON 引号包裹的 2~4 字纯中文，按出现次数排序 */
static NSArray *ScanRoleNames(task_t task, NSInteger limit) {
  NSMutableDictionary *freq = [NSMutableDictionary dictionary];
  vm_address_t address = 0;
  vm_size_t size = 0;
  natural_t depth = 0;

  while (YES) {
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t kr = vm_region_recurse_64(
        task, &address, &size, &depth, (vm_region_recurse_info_t)&info, &count);
    if (kr != KERN_SUCCESS) break;
    if (info.is_submap) {
      depth++;
      continue;
    }
    BOOL readable = (info.protection & VM_PROT_READ) != 0;
    // 角色 JSON 可能落在较大堆块，放宽到 96MB
    if (readable && size > 0 && size <= (96u * 1024u * 1024u)) {
      vm_offset_t data = 0;
      mach_msg_type_number_t dataCnt = 0;
      kr = vm_read(task, address, size, &data, &dataCnt);
      if (kr == KERN_SUCCESS && data && dataCnt > 0) {
        const uint8_t *buf = (const uint8_t *)(uintptr_t)data;
        size_t n = (size_t)dataCnt;
        for (size_t i = 0; i + 6 <= n; i++) {
          if (!IsCJKLead(buf[i])) continue;
          // 角色名以 2~4 字为主，只收引号包裹
          for (size_t chars = 4; chars >= 2; chars--) {
            size_t need = chars * 3;
            if (i + need > n) continue;
            size_t got = 0;
            if (!LooksLikeCNName(buf + i, need, &got)) continue;
            if (!IsQuotedCN(buf, n, i, need)) continue;
            NSString *s =
                [[NSString alloc] initWithBytes:buf + i
                                         length:need
                                       encoding:NSUTF8StringEncoding];
            if (!s.length || ShouldSkipName(s)) continue;
            NSInteger score = (freq[s] ? [freq[s] integerValue] : 0) + 1;
            if (chars == 3) score += 3;
            if (chars == 2) score += 1;
            freq[s] = @(score);
            break;
          }
        }
        vm_deallocate(mach_task_self(), data, dataCnt);
      }
    }
    address += size;
  }

  NSArray *sorted = [freq keysSortedByValueUsingComparator:^NSComparisonResult(
                              NSNumber *a, NSNumber *b) {
    return [b compare:a];
  }];
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *s in sorted) {
    if ((NSInteger)out.count >= limit) break;
    if ([freq[s] integerValue] < 2) continue;
    // 只要 2~4 字纯中文
    if (s.length < 2 || s.length > 4) continue;
    [out addObject:s];
  }
  return out;
}

static void DumpAround(task_t task, vm_address_t addr, size_t before, size_t after) {
  if (before > 4096) before = 4096;
  if (after > 8192) after = 8192;
  if (before < 16) before = 16;
  if (after < 16) after = 16;
  vm_address_t start = addr > before ? addr - before : 0;
  vm_size_t size = (vm_size_t)(before + after);
  vm_offset_t data = 0;
  mach_msg_type_number_t dataCnt = 0;
  kern_return_t kr = vm_read(task, start, size, &data, &dataCnt);
  if (kr != KERN_SUCCESS || !data || dataCnt == 0) {
    printf("{\"ok\":false,\"error\":\"vm_read\",\"kr\":%d}\n", (int)kr);
    return;
  }
  const uint8_t *buf = (const uint8_t *)(uintptr_t)data;
  size_t n = (size_t)dataCnt;
  size_t off = (size_t)(addr - start);
  if (off > n) off = 0;
  NSMutableString *hex = [NSMutableString string];
  for (size_t i = 0; i < n; i++) {
    [hex appendFormat:@"%02x", buf[i]];
  }
  NSMutableString *text = [NSMutableString string];
  for (size_t i = 0; i < n; i++) {
    uint8_t c = buf[i];
    if (c == 0) {
      [text appendString:@" "];
    } else if (c >= 32 && c < 127) {
      [text appendFormat:@"%c", c];
    } else if ((c & 0xF0) == 0xE0 && i + 2 < n) {
      NSString *ch = [[NSString alloc] initWithBytes:buf + i
                                              length:3
                                            encoding:NSUTF8StringEncoding];
      if (ch) [text appendString:ch];
      i += 2;
    } else {
      [text appendString:@"."];
    }
  }
  uint8_t prev = off > 0 ? buf[off - 1] : 0;
  uint8_t next = (off + 1 < n) ? buf[off + 1] : 0;
  printf("{\"ok\":true,\"address\":\"0x%lx\",\"prev\":%u,\"next\":%u,"
         "\"before\":%lu,\"after\":%lu,\"hex\":\"%s\",\"text\":\"%s\"}\n",
         (unsigned long)addr, (unsigned)prev, (unsigned)next,
         (unsigned long)before, (unsigned long)after, hex.UTF8String ?: "",
         JSONEscape(text).UTF8String ?: "");
  vm_deallocate(mach_task_self(), data, dataCnt);
}

/* 在 buf 中找 key":"value" ，写入 dict（memmem 加速） */
static void CollectJSONKV(const uint8_t *buf, size_t n, NSArray *keys,
                          NSMutableDictionary *out) {
  for (NSString *key in keys) {
    NSData *kd = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (!kd.length || kd.length > n) continue;
    const uint8_t *kb = kd.bytes;
    size_t kl = kd.length;
    const uint8_t *p = buf;
    size_t left = n;
    while (left >= kl + 4) {
      const uint8_t *hit = memmem(p, left, kb, kl);
      if (!hit) break;
      size_t i = (size_t)(hit - buf);
      size_t j = i + kl;
      if (j < n && buf[j] == '"') j++;
      if (j < n && buf[j] == ':') {
        j++;
        while (j < n && buf[j] == ' ') j++;
        if (j < n && buf[j] == '\\' && j + 1 < n && buf[j + 1] == '"')
          j += 2;
        else if (j < n && buf[j] == '"')
          j++;
        size_t vs = j;
        while (j < n && buf[j] != '"' && buf[j] != '\\' && buf[j] > 31) j++;
        if (j > vs && j - vs <= 128) {
          NSString *val =
              [[NSString alloc] initWithBytes:buf + vs
                                       length:j - vs
                                     encoding:NSUTF8StringEncoding];
          if (val.length) {
            NSString *old = out[key];
            if (!old || val.length >= old.length) out[key] = val;
          }
        }
      }
      size_t step = (size_t)(hit - p) + kl;
      if (step == 0) step = 1;
      if (step >= left) break;
      p += step;
      left -= step;
    }
  }
}

static BOOL LooksLikePlayerName(NSString *s) {
  if (!s || s.length < 2 || s.length > 16) return NO;
  if (ShouldSkipName(s)) return NO;
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (c >= 0x4E00 && c <= 0x9FFF) return YES;
  }
  return NO;
}

static BOOL LooksLikeItemName(NSString *s) {
  if (!s || s.length < 2 || s.length > 20) return NO;
  if (ShouldSkipName(s)) return NO;
  static NSArray *ui;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ui = @[
      @"确认", @"取消", @"关闭", @"返回", @"购买", @"出售", @"使用", @"穿戴",
      @"排行榜", @"角色", @"背包", @"属性", @"状态", @"装备", @"技能", @"称号",
      @"我的排名", @"未上榜", @"所属行会", @"查看", @"触摸层", @"开服公告",
      @"好运来", @"月卡", @"赞助", @"登录", @"公告", @"通知", @"规则", @"声明",
      @"提示", @"场景", @"列表", @"成功", @"失败", @"解封", @"合服", @"更新",
      @"防诈", @"公正", @"版本", @"账号", @"区服"
    ];
  });
  for (NSString *u in ui) {
    if ([s isEqualToString:u] || [s containsString:u]) return NO;
  }
  NSUInteger cjk = 0;
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (c >= 0x4E00 && c <= 0x9FFF) cjk++;
  }
  if (cjk < 2) return NO;
  BOOL itemish =
      [s containsString:@"剑"] || [s containsString:@"甲"] ||
      [s containsString:@"戒"] || [s containsString:@"腰带"] ||
      [s containsString:@"盔"] || [s containsString:@"靴"] ||
      [s containsString:@"石"] || [s containsString:@"丹"] ||
      [s containsString:@"卷"] || [s containsString:@"珠"] ||
      [s containsString:@"符"] || [s containsString:@"刃"] ||
      [s containsString:@"刀"] || [s containsString:@"杖"] ||
      [s containsString:@"衣"] || [s containsString:@"袍"] ||
      [s containsString:@"链"] || [s containsString:@"环"] ||
      [s containsString:@"勋章"] || [s containsString:@"材料"] ||
      [s containsString:@"礼包"] || [s containsString:@"箱子"] ||
      [s containsString:@"令"] || [s containsString:@"结晶"] ||
      [s containsString:@"铠"] || [s containsString:@"腕"] ||
      [s containsString:@"带"] || [s containsString:@"帽"];
  return itemish;
}

static NSDictionary *ExtractMode(task_t task, NSString *mode, NSInteger limit) {
  NSMutableDictionary *kv = [NSMutableDictionary dictionary];
  NSMutableArray *rankNames = [NSMutableArray array];
  NSMutableSet *seenRank = [NSMutableSet set];
  NSMutableArray *bagItems = [NSMutableArray array];
  NSMutableSet *seenBag = [NSMutableSet set];
  NSMutableDictionary *guildFreq = [NSMutableDictionary dictionary];

  NSArray *roleKeys = @[
    @"roleName", @"RoleName", @"roleAtt", @"roleLevel", @"roleJob", @"roleSex",
    @"roleRelive", @"turnLevel", @"relevel"
  ];

  BOOL wantChar = [mode isEqualToString:@"character"] ||
                  [mode isEqualToString:@"角色"] || [mode isEqualToString:@"role"];
  BOOL wantRank = [mode isEqualToString:@"rank"] ||
                  [mode isEqualToString:@"排行榜"] ||
                  [mode isEqualToString:@"leaderboard"];
  BOOL wantBag = [mode isEqualToString:@"bag"] || [mode isEqualToString:@"背包"] ||
                 [mode isEqualToString:@"backpack"];

  vm_address_t address = 0;
  vm_size_t size = 0;
  natural_t depth = 0;

  while (YES) {
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t kr = vm_region_recurse_64(
        task, &address, &size, &depth, (vm_region_recurse_info_t)&info, &count);
    if (kr != KERN_SUCCESS) break;
    if (info.is_submap) {
      depth++;
      continue;
    }
    BOOL readable = (info.protection & VM_PROT_READ) != 0;
    if (!(readable && size > 0 && size <= (96u * 1024u * 1024u))) {
      address += size;
      continue;
    }
    vm_offset_t data = 0;
    mach_msg_type_number_t dataCnt = 0;
    kr = vm_read(task, address, size, &data, &dataCnt);
    if (kr != KERN_SUCCESS || !data || dataCnt == 0) {
      address += size;
      continue;
    }
    const uint8_t *buf = (const uint8_t *)(uintptr_t)data;
    size_t n = (size_t)dataCnt;

    if (wantChar) {
      // 区域不含 role 则跳过，避免无扫
      if (memmem(buf, n, "role", 4) != NULL) {
        CollectJSONKV(buf, n, roleKeys, kv);
      }
    }

    if (wantRank) {
      // 以 \\\ 后缀定位排行名字（自后缀向前按 UTF-8 字回溯）
      const uint8_t *p = buf;
      size_t left = n;
      const char *suf = "\\\\\\";
      while (left >= 6 && (NSInteger)rankNames.count < limit) {
        const uint8_t *hit = memmem(p, left, suf, 3);
        if (!hit) break;
        size_t end = (size_t)(hit - buf);
        size_t i = end;
        size_t chars = 0;
        while (i >= 3 && chars < 16) {
          const uint8_t *ch = buf + (i - 3);
          if (!IsCJKLead(ch[0])) break;
          if ((ch[0] & 0xF0) != 0xE0) break;
          i -= 3;
          chars++;
        }
        if (chars >= 2 && i < end) {
          NSString *name =
              [[NSString alloc] initWithBytes:buf + i
                                       length:end - i
                                     encoding:NSUTF8StringEncoding];
          if (LooksLikePlayerName(name) && ![seenRank containsObject:name]) {
            [seenRank addObject:name];
            [rankNames addObject:name];
          }
        }
        size_t step = (size_t)(hit - p) + 3;
        if (step >= left) break;
        p += step;
        left -= step;
      }
      // 行会：只在含「江湖/行会」时细扫引号串
      if (memmem(buf, n, "江湖", 6) || memmem(buf, n, "行会", 6) ||
          memmem(buf, n, "梦", 3)) {
        for (size_t i = 0; i + 9 < n; i++) {
          if (!IsCJKLead(buf[i])) continue;
          for (size_t chars = 8; chars >= 3; chars--) {
            size_t need = chars * 3;
            if (i + need > n) continue;
            size_t got = 0;
            if (!LooksLikeCNName(buf + i, need, &got)) continue;
            if (!IsQuotedCN(buf, n, i, need)) continue;
            NSString *g =
                [[NSString alloc] initWithBytes:buf + i
                                         length:need
                                       encoding:NSUTF8StringEncoding];
            if (!g.length || ShouldSkipName(g)) continue;
            BOOL guildish =
                [g containsString:@"梦"] || [g containsString:@"会"] ||
                [g containsString:@"帮"] || [g containsString:@"盟"] ||
                [g containsString:@"江湖"];
            if (!guildish) continue;
            guildFreq[g] =
                @((guildFreq[g] ? [guildFreq[g] integerValue] : 0) + 1);
            break;
          }
        }
      }
    }

    if (wantBag) {
      // 有背包关键词的区域优先；否则也扫引号物品
      BOOL hot = memmem(buf, n, "背包", 6) || memmem(buf, n, "Item", 4) ||
                 memmem(buf, n, "bag", 3) || memmem(buf, n, "Goods", 5);
      if (!hot && size > (8u * 1024u * 1024u)) {
        // 大区域无关键词则跳过，控时
        vm_deallocate(mach_task_self(), data, dataCnt);
        address += size;
        continue;
      }
      for (size_t i = 0; i + 6 < n; i++) {
        if (!IsCJKLead(buf[i])) continue;
        for (size_t chars = 8; chars >= 2; chars--) {
          size_t need = chars * 3;
          if (i + need > n) continue;
          size_t got = 0;
          if (!LooksLikeCNName(buf + i, need, &got)) continue;
          if (!IsQuotedCN(buf, n, i, need)) continue;
          NSString *s =
              [[NSString alloc] initWithBytes:buf + i
                                       length:need
                                     encoding:NSUTF8StringEncoding];
          if (!LooksLikeItemName(s) || [seenBag containsObject:s]) continue;
          [seenBag addObject:s];
          [bagItems addObject:s];
          break;
        }
        if ((NSInteger)bagItems.count >= limit) break;
      }
    }

    vm_deallocate(mach_task_self(), data, dataCnt);
    address += size;
  }

  NSMutableArray *texts = [NSMutableArray array];
  NSMutableDictionary *dataOut = [NSMutableDictionary dictionary];

  if (wantChar) {
    NSString *name = kv[@"roleName"] ?: kv[@"RoleName"] ?: @"";
    NSString *att = kv[@"roleAtt"] ?: @"";
    NSString *level = kv[@"roleLevel"] ?: @"";
    NSString *relive =
        kv[@"roleRelive"] ?: kv[@"turnLevel"] ?: kv[@"relevel"] ?: @"";
    NSString *levelText = @"";
    if (relive.length && level.length)
      levelText = [NSString stringWithFormat:@"%@转%@级", relive, level];
    else if (level.length)
      levelText = [NSString stringWithFormat:@"%@级", level];
    if (name.length)
      [texts addObject:[NSString stringWithFormat:@"名称:%@", name]];
    if (att.length)
      [texts addObject:[NSString stringWithFormat:@"攻击:%@", att]];
    if (levelText.length)
      [texts addObject:[NSString stringWithFormat:@"等级:%@", levelText]];
    dataOut[@"name"] = name;
    dataOut[@"attack"] = att;
    dataOut[@"level"] = levelText;
  }

  if (wantRank) {
    NSString *guild = @"";
    NSArray *gsorted = [guildFreq
        keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a,
                                                             NSNumber *b) {
          return [b compare:a];
        }];
    if (gsorted.count) guild = gsorted[0];
    NSInteger idx = 1;
    for (NSString *name in rankNames) {
      if (idx > limit) break;
      [texts addObject:[NSString stringWithFormat:@"%ld|%@|%@", (long)idx, name,
                                                  guild.length ? guild : @"-"]];
      idx++;
    }
    dataOut[@"guild"] = guild;
  }

  if (wantBag) {
    NSInteger nadd = 0;
    for (NSString *it in bagItems) {
      if (nadd >= limit) break;
      [texts addObject:it];
      nadd++;
    }
  }

  return @{@"texts" : texts, @"data" : dataOut, @"ok" : @(texts.count > 0)};
}

static void PrintUsage(void) {
  fprintf(stderr,
          "usage:\n"
          "  ziyan_mem find <pid> <text> [--near BYTES] [--json]\n"
          "  ziyan_mem scan <pid> [--cn] [--min N] [--max N] [--limit N] [--json]\n"
          "  ziyan_mem role <pid> [--limit N] [--json]\n"
          "  ziyan_mem dump <pid> <addr_hex> [--before N] [--after N]\n"
          "  ziyan_mem extract <pid> <character|rank|bag|角色|排行榜|背包> "
          "[--limit N]\n");
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc < 3) {
      PrintUsage();
      return 2;
    }
    NSString *op = @(argv[1]);
    int pid = atoi(argv[2]);
    if (pid <= 1) {
      puts("{\"ok\":false,\"error\":\"bad_pid\"}");
      return 1;
    }

    BOOL scanCN = YES;
    NSInteger minC = 2, maxC = 6, limit = 40;
    size_t nearBytes = 2048;
    NSString *needleText = nil;

    if ([op isEqualToString:@"find"]) {
      if (argc < 4) {
        PrintUsage();
        return 2;
      }
      needleText = @(argv[3]);
      for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--near") && i + 1 < argc) {
          nearBytes = (size_t)atoi(argv[++i]);
        }
      }
      if (nearBytes < 256) nearBytes = 256;
      if (nearBytes > 64u * 1024u) nearBytes = 64u * 1024u;
    } else if ([op isEqualToString:@"scan"]) {
      for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--cn")) scanCN = YES;
        else if (!strcmp(argv[i], "--min") && i + 1 < argc) minC = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max") && i + 1 < argc) maxC = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = atoi(argv[++i]);
      }
      if (minC < 1) minC = 1;
      if (maxC < minC) maxC = minC;
      if (limit < 1) limit = 1;
      if (limit > 200) limit = 200;
    } else if ([op isEqualToString:@"role"]) {
      for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = atoi(argv[++i]);
      }
      if (limit < 1) limit = 1;
      if (limit > 40) limit = 40;
    } else if ([op isEqualToString:@"dump"]) {
      // handled below
    } else if ([op isEqualToString:@"extract"]) {
      if (argc < 4) {
        PrintUsage();
        return 2;
      }
      needleText = @(argv[3]); // mode
      for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = atoi(argv[++i]);
      }
      if (limit < 1) limit = 1;
      if (limit > 200) limit = 200;
    } else {
      PrintUsage();
      return 2;
    }

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
      printf("{\"ok\":false,\"error\":\"task_for_pid_failed\",\"kr\":%d,\"pid\":%d}\n",
             (int)kr, pid);
      return 1;
    }

    if ([op isEqualToString:@"dump"]) {
      if (argc < 4) {
        PrintUsage();
        mach_port_deallocate(mach_task_self(), task);
        return 2;
      }
      unsigned long addr = strtoul(argv[3], NULL, 0);
      size_t before = 256, after = 512;
      for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--before") && i + 1 < argc)
          before = (size_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--after") && i + 1 < argc)
          after = (size_t)atoi(argv[++i]);
      }
      DumpAround(task, (vm_address_t)addr, before, after);
      mach_port_deallocate(mach_task_self(), task);
      return 0;
    }

    if ([op isEqualToString:@"extract"]) {
      NSDictionary *r = ExtractMode(task, needleText ?: @"", limit);
      mach_port_deallocate(mach_task_self(), task);
      NSArray *texts = r[@"texts"] ?: @[];
      NSMutableString *tarr = [NSMutableString stringWithString:@"["];
      for (NSUInteger i = 0; i < texts.count; i++) {
        if (i) [tarr appendString:@","];
        [tarr appendFormat:@"\"%@\"", JSONEscape(texts[i])];
      }
      [tarr appendString:@"]"];
      BOOL ok = [r[@"ok"] boolValue];
      printf("{\"ok\":%s,\"pid\":%d,\"mode\":\"%s\",\"texts\":%s,\"count\":%lu}\n",
             ok ? "true" : "false", pid,
             JSONEscape(needleText).UTF8String ?: "",
             tarr.UTF8String ?: "[]", (unsigned long)texts.count);
      return ok ? 0 : 1;
    }

    if ([op isEqualToString:@"role"]) {
      NSArray *names = ScanRoleNames(task, limit);
      mach_port_deallocate(mach_task_self(), task);
      NSMutableString *tarr = [NSMutableString stringWithString:@"["];
      for (NSUInteger i = 0; i < names.count; i++) {
        if (i) [tarr appendString:@","];
        [tarr appendFormat:@"\"%@\"", JSONEscape(names[i])];
      }
      [tarr appendString:@"]"];
      printf("{\"ok\":%s,\"pid\":%d,\"texts\":%s,\"count\":%lu,\"names\":%s}\n",
             names.count ? "true" : "false", pid,
             tarr.UTF8String ?: "[]",
             (unsigned long)names.count,
             tarr.UTF8String ?: "[]");
      return names.count ? 0 : 1;
    }

    NSData *needle = nil;
    if (needleText.length) {
      needle = [needleText dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSMutableArray *texts = [NSMutableArray array];
    NSArray *hits = ScanRegions(task, needle ?: [NSData data],
                                needle != nil ? NO : scanCN, minC, maxC,
                                needle ? 8 : limit, nearBytes, texts);
    mach_port_deallocate(mach_task_self(), task);

    if ([op isEqualToString:@"find"]) {
      BOOL ok = hits.count > 0;
      NSString *text = ok ? hits[0][@"text"] : @"";
      NSString *addr = ok ? hits[0][@"address"] : @"";
      NSMutableString *tarr = [NSMutableString stringWithString:@"["];
      for (NSUInteger i = 0; i < texts.count; i++) {
        if (i) [tarr appendString:@","];
        [tarr appendFormat:@"\"%@\"", JSONEscape(texts[i])];
      }
      [tarr appendString:@"]"];
      printf("{\"ok\":%s,\"pid\":%d,\"text\":\"%s\",\"address\":\"%s\","
             "\"hits\":%lu,\"texts\":%s,\"count\":%lu}\n",
             ok ? "true" : "false", pid,
             JSONEscape(text).UTF8String ?: "",
             JSONEscape(addr).UTF8String ?: "",
             (unsigned long)hits.count,
             tarr.UTF8String ?: "[]",
             (unsigned long)texts.count);
      return ok ? 0 : 1;
    }

    NSMutableString *arr = [NSMutableString stringWithString:@"["];
    for (NSUInteger i = 0; i < hits.count; i++) {
      NSDictionary *h = hits[i];
      if (i) [arr appendString:@","];
      [arr appendFormat:@"{\"text\":\"%@\",\"address\":\"%@\"}",
                       JSONEscape(h[@"text"]), JSONEscape(h[@"address"])];
    }
    [arr appendString:@"]"];
    printf("{\"ok\":true,\"pid\":%d,\"count\":%lu,\"items\":%s}\n", pid,
           (unsigned long)hits.count, arr.UTF8String ?: "[]");
    return 0;
  }
}
