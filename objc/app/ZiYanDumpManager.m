#import "ZiYanDumpManager.h"
#import "ZiYanLLMSidecarClient.h"
#import "ZiYanPaths.h"
#import <unistd.h>

@implementation ZiYanDumpManager

+ (NSString *)safeAppDirName:(NSString *)name {
  NSMutableString *s = [NSMutableString stringWithString:name ?: @""];
  if (s.length == 0) {
    return @"";
  }
  NSCharacterSet *bad = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"]
      invertedSet];
  while ([s rangeOfCharacterFromSet:bad].location != NSNotFound) {
    NSRange r = [s rangeOfCharacterFromSet:bad];
    [s replaceCharactersInRange:r withString:@"_"];
  }
  NSString *stripped =
      [s stringByReplacingOccurrencesOfString:@"_" withString:@""];
  if (stripped.length == 0) {
    return @"";
  }
  return [s copy];
}

/// 从字符串抽样推断防御手段（限长，禁止在 SB 解析整包 Mach-O）
+ (NSDictionary *)analyzeDefenseFromStrings:(NSArray *)stringsSample
                                       bid:(NSString *)bid {
  NSMutableArray *findings = [NSMutableArray array];
  NSMutableArray *hints = [NSMutableArray array];
  __block NSInteger score = 0;
  NSString *blob =
      [[stringsSample componentsJoinedByString:@"\n"] lowercaseString] ?: @"";
  void (^hit)(NSString *, NSString *, NSInteger) =
      ^(NSString *needle, NSString *finding, NSInteger pts) {
        if ([blob containsString:needle]) {
          if (![findings containsObject:finding]) {
            [findings addObject:finding];
            score += pts;
          }
        }
      };
  hit(@"cydia", @"jailbreak_detect_cydia", 2);
  hit(@"substrate", @"jailbreak_detect_substrate", 2);
  hit(@"/var/jb", @"jailbreak_detect_rootless_path", 2);
  hit(@"frida", @"anti_frida", 3);
  hit(@"ptrace", @"anti_debug_ptrace", 3);
  hit(@"sysctl", @"anti_debug_sysctl", 2);
  hit(@"getppid", @"anti_debug_getppid", 1);
  hit(@"dlopen", @"dynamic_load_check", 1);
  hit(@"mobileprovision", @"provision_check", 1);
  hit(@"fairplay", @"fairplay_stub", 1);
  hit(@"codesign", @"codesign_verify", 2);
  hit(@"lc_code_signature", @"macho_code_signature", 2);
  hit(@"openssl", @"crypto_present", 1);
  hit(@"iossecurity", @"ios_security_suite", 3);
  hit(@"jailbreak", @"jailbreak_string", 2);
  if (score >= 10) {
    [hints addObject:@"hide_jb_paths"];
    [hints addObject:@"anti_debug_soften"];
    [hints addObject:@"deny_frida_port"];
  } else if (score >= 5) {
    [hints addObject:@"hide_jb_paths"];
    [hints addObject:@"anti_debug_soften"];
  } else {
    [hints addObject:@"hide_jb_paths"];
  }
  NSString *risk = @"low";
  if (score >= 10)
    risk = @"high";
  else if (score >= 5)
    risk = @"medium";
  if (findings.count == 0) {
    [findings addObject:@"no_strong_defense_string_hit"];
  }
  return @{
    @"arch" : @"arm64",
    @"bid" : bid ?: @"",
    @"risk_level" : risk,
    @"risk_score" : @(score),
    @"findings" : findings,
    @"defense_hints" : hints,
  };
}

+ (NSDictionary *)buildSummaryForBundle:(NSString *)bundlePath
                                    bid:(NSString *)bid {
  NSMutableArray *macho = [NSMutableArray array];
  NSMutableArray *frameworks = [NSMutableArray array];
  NSMutableArray *resources = [NSMutableArray array];
  NSMutableArray *stringsSample = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (getuid() != 0) {
    [macho addObject:[NSString stringWithFormat:@"bundle=%@", bundlePath ?: @""]];
    [macho addObject:@"summary_skipped_non_root"];
    [macho addObject:[NSString stringWithFormat:@"bid=%@", bid ?: @""]];
    return @{
      @"macho" : macho,
      @"frameworks" : frameworks,
      @"resources" : resources,
      @"strings_sample" : stringsSample,
      @"uid" : @(getuid()),
    };
  }
  if (bundlePath.length && [fm fileExistsAtPath:bundlePath]) {
    [macho addObject:[NSString stringWithFormat:@"bundle=%@", bundlePath]];
    NSString *exec =
        [[bundlePath lastPathComponent] stringByDeletingPathExtension];
    NSString *execPath = [bundlePath stringByAppendingPathComponent:exec];
    if ([fm fileExistsAtPath:execPath]) {
      NSDictionary *attr = [fm attributesOfItemAtPath:execPath error:nil];
      [macho addObject:[NSString stringWithFormat:@"exec_size=%llu",
                                                   (unsigned long long)
                                                       attr.fileSize]];
    }
    NSString *fwDir = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSArray *fws = [fm contentsOfDirectoryAtPath:fwDir error:nil];
    NSUInteger n = 0;
    for (NSString *f in fws ?: @[]) {
      [frameworks addObject:f];
      if (++n >= 40)
        break;
    }
    for (NSString *rname in
         @[ @"Assets.car", @"Info.plist", @"PkgInfo", @"_CodeSignature" ]) {
      NSString *rp = [bundlePath stringByAppendingPathComponent:rname];
      if ([fm fileExistsAtPath:rp]) {
        [resources addObject:rname];
      }
    }
    // 分片限长：可执行文件前 64KB 字符串抽样（禁止整包解析）
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:execPath];
    NSData *head = [fh readDataOfLength:64 * 1024];
    [fh closeFile];
    if (head.length) {
      const uint8_t *b = head.bytes;
      NSMutableString *cur = [NSMutableString string];
      for (NSUInteger i = 0; i < head.length && stringsSample.count < 40; i++) {
        char c = (char)b[i];
        if (c >= 32 && c < 127) {
          [cur appendFormat:@"%c", c];
        } else {
          if (cur.length >= 6) {
            [stringsSample addObject:[cur copy]];
          }
          [cur setString:@""];
        }
      }
    }
  } else {
    [macho addObject:@"bundle_missing_or_unreadable"];
  }
  [macho addObject:[NSString stringWithFormat:@"bid=%@", bid ?: @""]];
  NSDictionary *localDef =
      [self analyzeDefenseFromStrings:stringsSample bid:bid];
  return @{
    @"macho" : macho,
    @"frameworks" : frameworks,
    @"resources" : resources,
    @"strings_sample" : stringsSample,
    @"local_defense" : localDef,
  };
}

/// 尽力组装 IPA/Payload/<App>.app 并尝试 zip（root only；非 root 写 SKIPPED）
+ (void)extractIpaTreeForApp:(ZiYanAppPick *)app
                        zycv:(NSString *)zycv
                          fm:(NSFileManager *)fm {
  NSString *ipaDir = [zycv stringByAppendingPathComponent:@"IPA"];
  [fm createDirectoryAtPath:ipaDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  if (getuid() != 0 || app.bundlePath.length == 0) {
    [[NSString stringWithFormat:
                   @"skipped_non_root_or_no_bundle\n"
                    @"hint=run_as_root_cli_for_full_ipa\n"
                    @"bundle=%@\n",
                   app.bundlePath ?: @""]
        writeToFile:[ipaDir stringByAppendingPathComponent:@"SKIPPED.txt"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    return;
  }
  NSString *appLeaf = [app.bundlePath lastPathComponent];
  NSString *payload =
      [[ipaDir stringByAppendingPathComponent:@"Payload"]
          stringByAppendingPathComponent:appLeaf];
  [fm createDirectoryAtPath:payload
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  // Info.plist + 主二进制（限 80MB）+ 签名目录名录
  for (NSString *item in @[ @"Info.plist", @"PkgInfo", @"_CodeSignature" ]) {
    NSString *src = [app.bundlePath stringByAppendingPathComponent:item];
    if ([fm fileExistsAtPath:src]) {
      NSString *dst = [payload stringByAppendingPathComponent:item];
      [fm removeItemAtPath:dst error:nil];
      [fm copyItemAtPath:src toPath:dst error:nil];
    }
  }
  NSString *execName =
      [[app.bundlePath lastPathComponent] stringByDeletingPathExtension];
  NSString *execSrc =
      [app.bundlePath stringByAppendingPathComponent:execName];
  NSDictionary *attr = [fm attributesOfItemAtPath:execSrc error:nil];
  unsigned long long sz = attr.fileSize;
  if (sz > 0 && sz < 80ULL * 1024ULL * 1024ULL) {
    NSString *dst = [payload stringByAppendingPathComponent:execName];
    [fm removeItemAtPath:dst error:nil];
    [fm copyItemAtPath:execSrc toPath:dst error:nil];
  }
  // Frameworks：逐个限 25MB，最多 12 个
  NSString *fwSrc =
      [app.bundlePath stringByAppendingPathComponent:@"Frameworks"];
  NSString *fwDst = [payload stringByAppendingPathComponent:@"Frameworks"];
  NSArray *fws = [fm contentsOfDirectoryAtPath:fwSrc error:nil];
  if (fws.count) {
    [fm createDirectoryAtPath:fwDst
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    NSUInteger copied = 0;
    for (NSString *f in fws) {
      if (copied >= 12)
        break;
      NSString *s = [fwSrc stringByAppendingPathComponent:f];
      NSDictionary *a = [fm attributesOfItemAtPath:s error:nil];
      if (a.fileSize > 25ULL * 1024ULL * 1024ULL)
        continue;
      NSString *d = [fwDst stringByAppendingPathComponent:f];
      [fm removeItemAtPath:d error:nil];
      if ([fm copyItemAtPath:s toPath:d error:nil]) {
        copied++;
      }
    }
  }
  // iOS SDK 无 system()：不在此 zip；Payload 树已就绪，主机可打包 .ipa
  NSString *ipaName =
      [[execName length] ? execName : @"App" stringByAppendingString:@".ipa"];
  NSString *ipaPath = [ipaDir stringByAppendingPathComponent:ipaName];
  (void)ipaPath;
  [@"Payload/ ready. Pack on host: zip -r App.ipa Payload\n"
      writeToFile:[ipaDir stringByAppendingPathComponent:@"PACK_HINT.txt"]
       atomically:YES
         encoding:NSUTF8StringEncoding
            error:nil];
}

+ (nullable NSString *)dumpAndAnalyze:(ZiYanAppPick *)app
                                error:(NSString **)errOut {
  if (!app.displayName.length && !app.bundleId.length) {
    if (errOut)
      *errOut = @"missing_app";
    return nil;
  }
  NSString *dirName = [self safeAppDirName:app.displayName];
  if (dirName.length == 0) {
    dirName = [self
        safeAppDirName:[app.bundleId
                           stringByReplacingOccurrencesOfString:@"."
                                                     withString:@"_"]];
  }
  if (dirName.length == 0) {
    dirName = @"DumpApp";
  }
  NSString *zycv =
      [ZiYanZYCVDirectory() stringByAppendingPathComponent:dirName];
  if ([dirName isEqualToString:@"res"] || [dirName isEqualToString:@"config"] ||
      [dirName isEqualToString:@"log"] || [dirName isEqualToString:@"tmp"] ||
      [dirName isEqualToString:@"App"]) {
    dirName = [@"Dump_" stringByAppendingString:dirName];
    zycv = [ZiYanZYCVDirectory() stringByAppendingPathComponent:dirName];
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *sub in
       @[ @"Mach-O", @"Framework", @"Resource", @"IPA" ]) {
    NSString *p = [zycv stringByAppendingPathComponent:sub];
    [fm createDirectoryAtPath:p
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }
  NSMutableDictionary *meta = [@{
    @"app_name" : app.displayName ?: @"",
    @"bid" : app.bundleId ?: @"",
    @"bundle_path" : app.bundlePath ?: @"",
    @"ts" : @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
    @"phase" : @"7.6.3-R8.4.1",
  } mutableCopy];
  NSString *metaPath = [zycv stringByAppendingPathComponent:@"dump_meta.json"];
  NSData *md = [NSJSONSerialization dataWithJSONObject:meta
                                               options:NSJSONWritingPrettyPrinted
                                                 error:nil];
  [md writeToFile:metaPath atomically:YES];

  // IPA Payload 树
  [self extractIpaTreeForApp:app zycv:zycv fm:fm];

  // Mach-O / Framework / Resource
  if (app.bundlePath.length) {
    NSString *execName =
        [[app.bundlePath lastPathComponent] stringByDeletingPathExtension];
    NSString *src = [app.bundlePath stringByAppendingPathComponent:execName];
    NSString *machoDir = [zycv stringByAppendingPathComponent:@"Mach-O"];
    if (getuid() != 0) {
      [[NSString stringWithFormat:@"skipped_non_root_copy\nsrc=%@\n"
                                   @"hint=use_cli_or_sb_helper\n",
                                   src ?: @""]
          writeToFile:[machoDir stringByAppendingPathComponent:@"SKIPPED.txt"]
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    } else {
      NSDictionary *attr = [fm attributesOfItemAtPath:src error:nil];
      unsigned long long sz = attr.fileSize;
      if (sz > 0 && sz < 80ULL * 1024ULL * 1024ULL) {
        NSString *dst = [machoDir stringByAppendingPathComponent:execName];
        [fm removeItemAtPath:dst error:nil];
        NSError *ce = nil;
        if (![fm copyItemAtPath:src toPath:dst error:&ce]) {
          [[NSString stringWithFormat:@"copy_fail %@\n",
                                      ce.localizedDescription ?: @"?"]
              writeToFile:[machoDir
                              stringByAppendingPathComponent:@"SKIPPED.txt"]
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
        }
      } else if (sz >= 80ULL * 1024ULL * 1024ULL) {
        [[NSString stringWithFormat:@"skipped_large_exec bytes=%llu\n", sz]
            writeToFile:[machoDir stringByAppendingPathComponent:@"SKIPPED.txt"]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
      }
      // Framework 拷贝（限数量/大小）+ list
      NSString *fwSrc =
          [app.bundlePath stringByAppendingPathComponent:@"Frameworks"];
      NSString *fwOut = [zycv stringByAppendingPathComponent:@"Framework"];
      NSArray *fws = [fm contentsOfDirectoryAtPath:fwSrc error:nil];
      NSString *list = fws.count ? [fws componentsJoinedByString:@"\n"] : @"";
      [list writeToFile:[fwOut stringByAppendingPathComponent:@"list.txt"]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
      NSUInteger copied = 0;
      for (NSString *f in fws ?: @[]) {
        if (copied >= 8)
          break;
        NSString *s = [fwSrc stringByAppendingPathComponent:f];
        NSDictionary *a = [fm attributesOfItemAtPath:s error:nil];
        if (a.fileSize > 20ULL * 1024ULL * 1024ULL)
          continue;
        NSString *d = [fwOut stringByAppendingPathComponent:f];
        [fm removeItemAtPath:d error:nil];
        if ([fm copyItemAtPath:s toPath:d error:nil])
          copied++;
      }
      // Resource：Info.plist / Assets.car（Assets 过大则只记名）
      NSString *resOut = [zycv stringByAppendingPathComponent:@"Resource"];
      NSString *infoSrc =
          [app.bundlePath stringByAppendingPathComponent:@"Info.plist"];
      if ([fm fileExistsAtPath:infoSrc]) {
        [fm removeItemAtPath:[resOut stringByAppendingPathComponent:@"Info.plist"]
                       error:nil];
        [fm copyItemAtPath:infoSrc
                    toPath:[resOut stringByAppendingPathComponent:@"Info.plist"]
                     error:nil];
      }
      NSString *car =
          [app.bundlePath stringByAppendingPathComponent:@"Assets.car"];
      if ([fm fileExistsAtPath:car]) {
        NSDictionary *ca = [fm attributesOfItemAtPath:car error:nil];
        if (ca.fileSize < 15ULL * 1024ULL * 1024ULL) {
          [fm removeItemAtPath:[resOut stringByAppendingPathComponent:@"Assets.car"]
                         error:nil];
          [fm copyItemAtPath:car
                      toPath:[resOut stringByAppendingPathComponent:@"Assets.car"]
                       error:nil];
        } else {
          [[NSString stringWithFormat:@"Assets.car bytes=%llu (not copied)\n",
                                      (unsigned long long)ca.fileSize]
              writeToFile:[resOut stringByAppendingPathComponent:@"Assets.car.txt"]
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
        }
      }
    }
  }

  NSDictionary *summary =
      [self buildSummaryForBundle:app.bundlePath bid:app.bundleId];
  NSDictionary *req = @{
    @"app_name" : app.displayName ?: @"",
    @"bid" : app.bundleId ?: @"",
    @"zycv_path" : zycv,
    @"summary" : summary,
    @"endpoint" : @"/v1/dump_analyze/run",
  };
  NSString *scErr = nil;
  NSDictionary *result =
      [ZiYanLLMSidecarClient runDumpAnalyze:req timeoutSec:20.0 error:&scErr];
  NSString *reportMd = nil;
  NSDictionary *reportJson = nil;
  if ([result[@"ok"] boolValue]) {
    if ([result[@"report_md"] isKindOfClass:[NSString class]]) {
      reportMd = result[@"report_md"];
    }
    if ([result[@"report_json"] isKindOfClass:[NSDictionary class]]) {
      reportJson = result[@"report_json"];
    }
  }
  NSDictionary *localDef = summary[@"local_defense"];
  if (![localDef isKindOfClass:[NSDictionary class]]) {
    localDef = [self analyzeDefenseFromStrings:summary[@"strings_sample"] ?: @[]
                                           bid:app.bundleId];
  }
  // 侧车报告过短或缺 risk → 用本地启发式补全/覆盖
  BOOL thinMd = reportMd.length < 80;
  BOOL thinJson = !reportJson || ![reportJson[@"risk_level"] isKindOfClass:[NSString class]] ||
                  [reportJson[@"risk_level"] isEqualToString:@"unknown"];
  if (thinJson) {
    NSMutableDictionary *merged = [@{
      @"arch" : localDef[@"arch"] ?: @"arm64",
      @"risk_level" : localDef[@"risk_level"] ?: @"unknown",
      @"risk_score" : localDef[@"risk_score"] ?: @0,
      @"findings" : localDef[@"findings"] ?: @[ @"local_heuristic" ],
      @"defense_hints" : localDef[@"defense_hints"] ?: @[ @"hide_jb_paths" ],
      @"summary" : summary,
      @"source" : @"local_heuristic_r841",
    } mutableCopy];
    if ([reportJson isKindOfClass:[NSDictionary class]]) {
      [merged addEntriesFromDictionary:reportJson];
      // 保留本地 risk 若侧车未给
      if (!reportJson[@"risk_level"] ||
          [reportJson[@"risk_level"] isEqualToString:@"unknown"]) {
        merged[@"risk_level"] = localDef[@"risk_level"] ?: @"low";
        merged[@"risk_score"] = localDef[@"risk_score"] ?: @0;
        merged[@"findings"] = localDef[@"findings"] ?: merged[@"findings"];
        merged[@"defense_hints"] =
            localDef[@"defense_hints"] ?: merged[@"defense_hints"];
      }
      merged[@"source"] = @"sidecar+local_r841";
    }
    reportJson = merged;
  }
  if (!reportMd.length || thinMd) {
    reportMd = [NSString
        stringWithFormat:
            @"# 脱壳分析报告 · R8.4.1\n\n"
             @"- app: %@\n- bid: %@\n- zycv: %@\n"
             @"- sidecar: %@\n- risk: %@ (score=%@)\n\n"
             @"## Findings\n%@\n\n"
             @"## Defense hints\n%@\n\n"
             @"## Summary\n```\n%@\n```\n\n"
             @"侧车协议：POST /v1/dump_analyze/run（文件投递回退已用）。\n"
             @"Mach-O 仅分片限长抽样，禁止 SB 整包解析。\n",
            app.displayName ?: @"", app.bundleId ?: @"", zycv,
            scErr ?: @"ok_or_local", reportJson[@"risk_level"] ?: @"?",
            reportJson[@"risk_score"] ?: @0,
            [reportJson[@"findings"] isKindOfClass:[NSArray class]]
                ? [reportJson[@"findings"] componentsJoinedByString:@"\n- "]
                : @"-",
            [reportJson[@"defense_hints"] isKindOfClass:[NSArray class]]
                ? [reportJson[@"defense_hints"] componentsJoinedByString:@"\n- "]
                : @"-",
            summary];
    if (errOut && scErr.length) {
      *errOut = scErr;
    }
  }
  NSString *mdPath = [zycv stringByAppendingPathComponent:@"ANALYSIS.md"];
  [reportMd writeToFile:mdPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  NSData *rj =
      [NSJSONSerialization dataWithJSONObject:reportJson
                                      options:NSJSONWritingPrettyPrinted
                                        error:nil];
  [rj writeToFile:[zycv stringByAppendingPathComponent:@"analysis.json"]
       atomically:YES];

  // 自我进化：防御回写
  {
    NSString *resDir =
        [ZiYanZYCVDirectory() stringByAppendingPathComponent:@"res"];
    [fm createDirectoryAtPath:resDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    NSDictionary *feed = @{
      @"ts" : @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
      @"source" : @"auto_dump",
      @"app_name" : app.displayName ?: @"",
      @"bid" : app.bundleId ?: @"",
      @"zycv_path" : zycv,
      @"analysis" : reportJson ?: @{},
      @"purpose" : @"self_defense_enhance",
      @"phase" : @"7.6.3-R8.4.1",
      @"models" : result[@"models"] ?: [NSNull null],
    };
    NSData *fd =
        [NSJSONSerialization dataWithJSONObject:feed
                                        options:NSJSONWritingPrettyPrinted
                                          error:nil];
    [fd writeToFile:[resDir stringByAppendingPathComponent:@"dump_defense_feed.json"]
         atomically:YES];
    [fd writeToFile:[zycv stringByAppendingPathComponent:@"defense_hints.json"]
         atomically:YES];
  }
  return zycv;
}

@end
