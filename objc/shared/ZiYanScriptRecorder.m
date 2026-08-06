#import "ZiYanScriptRecorder.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>
#import <sys/stat.h>

@implementation ZiYanScriptRecorder

+ (NSString *)armedPath {
  return ZiYanVarFile(@".ziyan_rec_armed");
}
+ (NSString *)recPath {
  return ZiYanVarFile(@".ziyan_recording");
}
+ (NSString *)eventsPath {
  return ZiYanVarFile(@".ziyan_rec_events.jsonl");
}
+ (NSString *)lastPathFile {
  return ZiYanVarFile(@".ziyan_rec_last.json");
}

+ (BOOL)isArmed {
  return [[NSFileManager defaultManager] fileExistsAtPath:[self armedPath]];
}
+ (BOOL)isRecording {
  return [[NSFileManager defaultManager] fileExistsAtPath:[self recPath]];
}

+ (BOOL)armWithBundleId:(NSString *)bid
                appName:(NSString *)name
                  error:(NSString **)errOut {
  ZiYanEnsureVarDirectory();
  ZiYanEnsureScriptsDirectory();
  NSDictionary *doc = @{
    @"bid" : bid ?: @"",
    @"app_name" : name ?: @"",
    @"ts" : @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
    @"note" : @"press_volume_up_to_start",
    @"paid_api" : @NO,
  };
  NSData *d = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
  if (![d writeToFile:[self armedPath] atomically:YES]) {
    if (errOut)
      *errOut = @"arm_write_fail";
    return NO;
  }
  [[NSFileManager defaultManager] removeItemAtPath:[self recPath] error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:[self eventsPath] error:nil];
  return YES;
}

+ (void)disarm {
  [[NSFileManager defaultManager] removeItemAtPath:[self armedPath] error:nil];
}

+ (void)resetSessionOnAppColdLaunch {
  // 冷启动 ≠ 用户点「录制脚本」武装；残留 .ziyan_rec_armed / .ziyan_recording
  // 会在 Volume 回中误触发音量+时自动开始录制，必须清掉。
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:[self armedPath] error:nil];
  [fm removeItemAtPath:[self recPath] error:nil];
  [fm removeItemAtPath:[self eventsPath] error:nil];
}

+ (void)appendTapLogicX:(double)x y:(double)y holdMs:(NSInteger)holdMs {
  if (![self isRecording])
    return;
  ZiYanEnsureVarDirectory();
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  static NSTimeInterval sLast = 0;
  static NSTimeInterval sRecEpoch = 0;
  // 新开录制会话：读 rec.started 重置间隔
  NSString *recMeta =
      [NSString stringWithContentsOfFile:[self recPath]
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  id mo = recMeta.length
              ? [NSJSONSerialization
                    JSONObjectWithData:[recMeta dataUsingEncoding:NSUTF8StringEncoding]
                               options:0
                                 error:nil]
              : nil;
  NSTimeInterval started =
      [mo isKindOfClass:[NSDictionary class]]
          ? [mo[@"started"] doubleValue] / 1000.0
          : 0;
  if (started > 1 && fabs(started - sRecEpoch) > 0.01) {
    sRecEpoch = started;
    sLast = 0;
  }
  NSInteger gap = 0;
  if (sLast > 1) {
    gap = (NSInteger)lround((now - sLast) * 1000.0);
    if (gap < 0)
      gap = 0;
    if (gap > 60000)
      gap = 60000;
  }
  sLast = now;
  NSDictionary *ev = @{
    @"t" : @((long long)(now * 1000.0)),
    @"type" : @"tap",
    @"x" : @((NSInteger)lround(x)),
    @"y" : @((NSInteger)lround(y)),
    @"hold_ms" : @(holdMs > 0 ? holdMs : 0),
    @"gap_ms" : @(gap),
  };
  NSData *line =
      [NSJSONSerialization dataWithJSONObject:ev options:0 error:nil];
  if (!line.length)
    return;
  NSFileHandle *fh =
      [NSFileHandle fileHandleForWritingAtPath:[self eventsPath]];
  if (!fh) {
    [[NSString stringWithFormat:@"%@\n",
                                [[NSString alloc] initWithData:line
                                                      encoding:NSUTF8StringEncoding]]
        writeToFile:[self eventsPath]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    return;
  }
  [fh seekToEndOfFile];
  [fh writeData:line];
  [fh writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
}

+ (NSString *)luaFromEvents:(NSArray *)events bid:(NSString *)bid name:(NSString *)name {
  NSMutableString *body = [NSMutableString string];
  [body appendFormat:
            @"-- ZiYan recorded script R8.4.12 (volume+ record)\n"
             @"-- app=%@ bid=%@\n"
             @"-- 学触动音量加录制思路；禁止触动私有模块；坐标=逻辑，回放走引擎 tap\n"
             @"function main()\n"
             @"  init(1)\n"
             @"  local BID = \"%@\"\n"
             @"  -- keepScreen：批量找色前可开；录制回放以 tap 为主\n",
        name.length ? name : @"-", bid.length ? bid : @"-",
        bid.length ? bid : @""];
  NSInteger n = 0;
  for (id it in events) {
    if (![it isKindOfClass:[NSDictionary class]])
      continue;
    if (![[it[@"type"] description] isEqualToString:@"tap"])
      continue;
    NSInteger gap = [it[@"gap_ms"] integerValue];
    if (n > 0 && gap > 30) {
      [body appendFormat:@"  mSleep(%ld)\n", (long)gap];
    } else if (n > 0) {
      [body appendString:@"  mSleep(120)\n"];
    }
    NSInteger x = [it[@"x"] integerValue];
    NSInteger y = [it[@"y"] integerValue];
    NSInteger hold = [it[@"hold_ms"] integerValue];
    if (hold >= 350) {
      [body appendFormat:
                @"  -- long tap\n"
                 @"  if type(touchDown) == \"function\" then\n"
                 @"    touchDown(1, %ld, %ld); mSleep(%ld); touchUp(1, %ld, %ld)\n"
                 @"  else\n"
                 @"    tap(%ld, %ld)\n"
                 @"  end\n",
            (long)x, (long)y, (long)hold, (long)x, (long)y, (long)x, (long)y];
    } else {
      [body appendFormat:@"  tap(%ld, %ld)\n", (long)x, (long)y];
    }
    n++;
  }
  if (n == 0) {
    [body appendString:@"  toast(\"录制为空：无点击事件\", 2000)\n"];
  } else {
    [body appendFormat:@"  toast(\"录制回放完成 taps=%ld\", 1500)\n", (long)n];
  }
  [body appendString:@"end\n\nmain()\n"];
  return body;
}

+ (BOOL)toggleFromVolumeUpSavedPath:(NSString **)pathOut
                              error:(NSString **)errOut {
  static NSTimeInterval sLast = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now - sLast < 0.85) {
    if (errOut)
      *errOut = @"debounce";
    return YES; // 吞重复键
  }
  sLast = now;

  if ([self isRecording]) {
    // 停止并落盘
    NSString *armedRaw =
        [NSString stringWithContentsOfFile:[self armedPath]
                                  encoding:NSUTF8StringEncoding
                                     error:nil] ?: @"{}";
    // armed 可能在 start 时已删；读 rec meta
    NSString *recMeta =
        [NSString stringWithContentsOfFile:[self recPath]
                                  encoding:NSUTF8StringEncoding
                                     error:nil] ?: @"{}";
    id metaObj =
        [NSJSONSerialization JSONObjectWithData:[recMeta dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0
                                          error:nil];
    if (![metaObj isKindOfClass:[NSDictionary class]]) {
      metaObj = [NSJSONSerialization
          JSONObjectWithData:[armedRaw dataUsingEncoding:NSUTF8StringEncoding]
                     options:0
                       error:nil];
    }
    NSDictionary *meta =
        [metaObj isKindOfClass:[NSDictionary class]] ? metaObj : @{};
    NSString *bid = [meta[@"bid"] description] ?: @"";
    NSString *name = [meta[@"app_name"] description] ?: @"rec";

    NSMutableArray *events = [NSMutableArray array];
    NSString *raw =
        [NSString stringWithContentsOfFile:[self eventsPath]
                                  encoding:NSUTF8StringEncoding
                                     error:nil] ?: @"";
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
      if (line.length < 4)
        continue;
      id o = [NSJSONSerialization
          JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                     options:0
                       error:nil];
      if ([o isKindOfClass:[NSDictionary class]])
        [events addObject:o];
    }
    NSString *lua = [self luaFromEvents:events bid:bid name:name];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *base =
        [NSString stringWithFormat:@"rec_%@", [fmt stringFromDate:[NSDate date]]];
    NSString *path = [ZiYanScriptsDirectory()
        stringByAppendingPathComponent:[base stringByAppendingString:@".lua"]];
    NSError *we = nil;
    if (![lua writeToFile:path
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:&we]) {
      if (errOut)
        *errOut = we.localizedDescription ?: @"write_fail";
      [[NSFileManager defaultManager] removeItemAtPath:[self recPath] error:nil];
      return YES;
    }
    chmod(path.fileSystemRepresentation, 0644);
    NSDictionary *last = @{
      @"path" : path,
      @"taps" : @(events.count),
      @"bid" : bid,
      @"pipeline" : @"Record[Vol+→Touch→Lua]",
      @"paid_api" : @NO,
      @"ts" : @((long long)(now * 1000.0)),
    };
    NSData *ld = [NSJSONSerialization dataWithJSONObject:last options:0 error:nil];
    [ld writeToFile:[self lastPathFile] atomically:YES];
    [ld writeToFile:[ZiYanScriptsDirectory()
                        stringByAppendingPathComponent:@".scriptgen_last.json"]
         atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:[self recPath] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self armedPath] error:nil];
    if (pathOut)
      *pathOut = path;
    return YES;
  }

  if (![self isArmed]) {
    return NO; // 未武装：不抢音量+
  }

  // 开始录制
  NSString *armedRaw =
      [NSString stringWithContentsOfFile:[self armedPath]
                                encoding:NSUTF8StringEncoding
                                   error:nil] ?: @"{}";
  id armedObj = [NSJSONSerialization
      JSONObjectWithData:[armedRaw dataUsingEncoding:NSUTF8StringEncoding]
                 options:0
                   error:nil];
  NSMutableDictionary *meta =
      [armedObj isKindOfClass:[NSDictionary class]]
          ? [armedObj mutableCopy]
          : [NSMutableDictionary dictionary];
  meta[@"started"] = @((long long)(now * 1000.0));
  meta[@"recording"] = @YES;
  NSData *md = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
  [md writeToFile:[self recPath] atomically:YES];
  [@"" writeToFile:[self eventsPath]
        atomically:YES
          encoding:NSUTF8StringEncoding
             error:nil];
  // 保留 armed 直至停止（便于读 bid）；也可用 rec meta
  return YES;
}

+ (NSString *)lastSavedPath {
  NSData *d = [NSData dataWithContentsOfFile:[self lastPathFile]];
  if (!d.length)
    return nil;
  id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  if ([o isKindOfClass:[NSDictionary class]])
    return [o[@"path"] description];
  return nil;
}

@end
