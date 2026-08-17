#import "AgentVersionStore.h"
#import "ZiYanPaths.h"

@implementation AgentVersionInfo
@end

@implementation AgentVersionStore

+ (NSString *)agentRoot {
  return [ZiYanScriptsDirectory() stringByAppendingPathComponent:@"Agent游戏"];
}

+ (NSString *)learnDataDir {
  return [[self agentRoot] stringByAppendingPathComponent:@"学习数据"];
}

+ (NSString *)runLogDir {
  return [[self agentRoot] stringByAppendingPathComponent:@"运行记录"];
}

+ (NSString *)genScriptDir {
  return [[self agentRoot] stringByAppendingPathComponent:@"生成脚本"];
}

+ (void)ensureDirs {
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *d in @[
         [self agentRoot], [self learnDataDir], [self runLogDir],
         [self genScriptDir],
         [[self agentRoot] stringByAppendingPathComponent:@"游戏配置"],
         [[self agentRoot] stringByAppendingPathComponent:@"临时缓存"],
         [[self agentRoot] stringByAppendingPathComponent:@"会话"]
       ]) {
    [fm createDirectoryAtPath:d
        withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions : @0755}
                              error:nil];
  }
}

+ (NSString *)pinyinStemForName:(NSString *)name {
  if (name.length == 0) {
    return @"YouXi";
  }
  NSDictionary *map = @{
    @"龙界争霸-拔刀传奇" : @"LongJieZhengBa_BaDaoChuanQi",
    @"龙界争霸" : @"LongJieZhengBa",
    @"赤沙龙城" : @"ChiShaLongCheng",
    @"血战屠龙" : @"XueZhanTuLong",
    @"触动专业版" : @"ChuDongZhuanYeBan",
    @"战神域-攻速三职业" : @"ZhanShenYu",
    @"simNote" : @"SimNote",
  };
  NSString *hit = map[name];
  if (hit.length) {
    return hit;
  }
  NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9')) {
      if (out.length == 0 && c >= 'a' && c <= 'z') {
        [out appendFormat:@"%c", c - 32];
      } else {
        [out appendFormat:@"%c", c];
      }
    } else if (c == '-' || c == '_' || c == ' ') {
      if (out.length && ![out hasSuffix:@"_"]) {
        [out appendString:@"_"];
      }
    }
  }
  if (out.length == 0) {
    return @"YouXi";
  }
  return out;
}

+ (BOOL)isUserHandwrittenPath:(NSString *)path {
  NSString *base = path.lastPathComponent ?: @"";
  if ([base containsString:@"_学习草稿"] ||
      [base containsString:@"_自研草稿"]) {
    return NO;
  }
  return YES;
}

+ (AgentVersionInfo *)latestForBundleId:(NSString *)bid name:(NSString *)name {
  NSString *stem = [self pinyinStemForName:name];
  NSFileManager *fm = [NSFileManager defaultManager];
  AgentVersionInfo *best = nil;
  NSArray *dirs = @[ ZiYanScriptsDirectory(), ZiYanUserLuaDirectory() ];
  for (NSString *dir in dirs) {
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *fn in names ?: @[]) {
      if (![fn hasSuffix:@".lua"]) {
        continue;
      }
      if (![fn hasPrefix:stem] && name.length > 0 &&
          ![fn containsString:stem]) {
        continue;
      }
      AgentArtifactKind kind = AgentArtifactNone;
      NSInteger ver = 0;
      NSString *full = [dir stringByAppendingPathComponent:fn];
      if ([self isQuarantinedPath:full] || [fn containsString:@"_自研草稿"]) {
        continue;
      }
      if ([fn containsString:@"_学习草稿"]) {
        kind = AgentArtifactLearnDraft;
        ver = 0;
      } else if ([fn containsString:@"_自研草稿_v"]) {
        kind = AgentArtifactSelfDraft;
        NSString *tail = [fn componentsSeparatedByString:@"_自研草稿_v"].lastObject;
        ver = tail.integerValue;
      } else {
        continue;
      }
      if (!best || ver > best.version ||
          (kind == AgentArtifactSelfDraft &&
           best.kind == AgentArtifactLearnDraft)) {
        AgentVersionInfo *info = [AgentVersionInfo new];
        info.gameName = name;
        info.bundleId = bid;
        info.stem = stem;
        info.version = ver;
        info.kind = kind;
        info.luaPath = [dir stringByAppendingPathComponent:fn];
        info.jsonPath =
            [[info.luaPath stringByDeletingPathExtension]
                stringByAppendingPathExtension:@"json"];
        info.kindLabel = (kind == AgentArtifactLearnDraft) ? @"学习草稿"
                                                           : @"自研草稿";
        best = info;
      }
    }
  }
  return best;
}

+ (NSString *)unusedLearnLuaPathForStem:(NSString *)stem {
  NSString *dir = ZiYanScriptsDirectory();
  NSString *base =
      [dir stringByAppendingPathComponent:
               [NSString stringWithFormat:@"%@_学习草稿.lua", stem]];
  if (![[NSFileManager defaultManager] fileExistsAtPath:base]) {
    return base;
  }
  for (NSInteger i = 2; i < 99; i++) {
    NSString *p = [dir
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_学习草稿_v%ld.lua", stem, (long)i]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
      return p;
    }
  }
  return [dir stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"%@_学习草稿_%lld.lua", stem,
                                             (long long)[[NSDate date]
                                                 timeIntervalSince1970]]];
}

+ (NSString *)unusedSelfLuaPathForStem:(NSString *)stem
                               version:(NSInteger)ver {
  NSString *dir = ZiYanScriptsDirectory();
  NSString *p = [dir
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%@_自研草稿_v%ld.lua", stem, (long)ver]];
  if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
    return p;
  }
  return [dir stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"%@_自研草稿_v%ld_%lld.lua", stem,
                                             (long)ver,
                                             (long long)[[NSDate date]
                                                 timeIntervalSince1970]]];
}

+ (void)writeCopyOnWrite:(NSString *)path body:(NSString *)body {
  if (path.length == 0 || [self isUserHandwrittenPath:path]) {
    if ([self isUserHandwrittenPath:path] &&
        [[NSFileManager defaultManager] fileExistsAtPath:path]) {
      return;
    }
  }
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return;
  }
  [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (BOOL)isQuarantinedPath:(NSString *)path {
  if (path.length == 0) {
    return NO;
  }
  NSString *q = [path stringByAppendingString:@".quarantine"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:q]) {
    return YES;
  }
  NSString *base = path.lastPathComponent ?: @"";
  return [base hasPrefix:@"SimNote_自研草稿"];
}

+ (void)quarantineSimArtifacts {
  [self ensureDirs];
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *dir in @[ ZiYanScriptsDirectory(), ZiYanUserLuaDirectory() ]) {
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *fn in names ?: @[]) {
      if (![fn hasPrefix:@"SimNote_自研草稿"] || ![fn hasSuffix:@".lua"]) {
        continue;
      }
      NSString *lua = [dir stringByAppendingPathComponent:fn];
      NSString *q = [lua stringByAppendingString:@".quarantine"];
      if ([fm fileExistsAtPath:q]) {
        continue;
      }
      NSString *body =
          @"valid=false\nsource=cursor_simulation\n"
          @"excluded_from_iteration=true\n"
          @"note=invalid_test_artifact\n";
      [body writeToFile:q atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
  }
}

@end
