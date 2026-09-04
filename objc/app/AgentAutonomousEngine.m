#import "AgentAutonomousEngine.h"
#import "AgentVersionStore.h"
#import "ZiYanScriptRunner.h"
#import "ZiYanPaths.h"

@interface AgentAutonomousEngine ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSDictionary *lastResult;
@property (nonatomic, copy) NSString *gameName;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *launcherPath;
@end

@implementation AgentAutonomousEngine

+ (instancetype)shared {
  static AgentAutonomousEngine *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[AgentAutonomousEngine alloc] init];
  });
  return s;
}

- (void)startExploreName:(NSString *)name bid:(NSString *)bid {
  [self cancel];
  if (name.length == 0 || bid.length == 0) {
    self.lastResult = @{@"status" : @"PRE_BLOCKED",
                        @"reason" : @"gameplay_target_required"};
    return;
  }
  [AgentVersionStore ensureDirs];
  self.gameName = name;
  self.bundleId = bid;
  NSString *sid = [NSString
      stringWithFormat:@"gameplay_%lld",
                       (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
  self.launcherPath =
      [[AgentVersionStore genScriptDir]
          stringByAppendingPathComponent:
              [NSString stringWithFormat:@"gameplay_%@.lua", sid]];
  NSString *source = [NSString
      stringWithFormat:
          @"-- AI-GAMEPLAY-LAUNCHER\n"
           "if type(Zy) ~= \"table\" then require(\"modules\") end\n"
           "local report = Zy.AI.pipeline(\"世界/玩法/自研/探索\", {\n"
           "  bid = %@, design_w = 1136, design_h = 640,\n"
           "  gameplay = true, real_device = true, skip_repair = true,\n"
           "  save_anyway = true, require_running = false,\n"
           "  name = %@,\n"
           "})\n"
           "local ok = report and report.ok == true\n"
           "local reason = report and report.detail and (report.detail.reason or report.detail.err) or \"no_report\"\n"
           "local var = Zy.File.varDir()\n"
           "Zy.File.write(var .. \"/.ziyan_agent_gameplay_launcher_result\", string.format(\"ok=%%s\\npath=%%s\\nreason=%%s\\n\", tostring(ok), tostring(report and report.path or \"\"), tostring(reason)))\n"
           "return report\n",
          [self luaQuote:bid], [self luaQuote:(name ?: @"YouXi")]];
  [source writeToFile:self.launcherPath
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:nil];
  self.running = YES;
  self.lastResult = @{
    @"status" : @"EXPLORING",
    @"phase" : @"P3",
    @"game" : name,
    @"bundle_id" : bid,
    @"launcher" : self.launcherPath,
  };
  [self writeResultProbe:@"started"];
  NSString *path = self.launcherPath;
  [ZiYanScriptRunner runFileAtPath:path
                         completion:^(BOOL success, NSInteger exitCode,
                                      NSString *output) {
                           self.running = NO;
                           self.lastResult = @{
                             @"status" : success ? @"PIPELINE_FINISHED"
                                                  : @"PIPELINE_FAILED",
                             @"phase" : @"P3",
                             @"game" : self.gameName ?: @"",
                             @"bundle_id" : self.bundleId ?: @"",
                             @"launcher" : path ?: @"",
                             @"exit_code" : @(exitCode),
                             @"output" : output ?: @"",
                           };
                           [self writeResultProbe:success ? @"finished"
                                                               : @"failed"];
                         }];
}

- (void)startIterateName:(NSString *)name
                     bid:(NSString *)bid
                 version:(NSInteger)ver
                    kind:(NSString *)kind {
  (void)ver;
  (void)kind;
  [self startExploreName:name bid:bid];
}

- (void)cancel {
  self.running = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)stopAndGenerate {
  NSDictionary *before = self.lastResult ?: @{};
  [ZiYanScriptRunner stopCurrentRun];
  [self cancel];
  NSString *pipelinePath = [self pipelinePathFromSummary];
  NSString *source = pipelinePath.length
                         ? [NSString stringWithContentsOfFile:pipelinePath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil]
                         : nil;
  if (source.length == 0) {
    source = [NSString stringWithContentsOfFile:self.launcherPath
                                       encoding:NSUTF8StringEncoding
                                          error:nil];
  }
  NSString *stem = [AgentVersionStore pinyinStemForName:self.gameName];
  AgentVersionInfo *latest =
      [AgentVersionStore latestForBundleId:self.bundleId name:self.gameName];
  NSInteger version = MAX(1, (latest ? latest.version : 0) + 1);
  NSString *draft =
      [AgentVersionStore unusedSelfLuaPathForStem:stem version:version];
  NSString *json =
      [[draft stringByDeletingPathExtension]
          stringByAppendingPathExtension:@"json"];
  BOOL wrote = source.length > 0;
  if (wrote) {
    [AgentVersionStore writeCopyOnWrite:draft body:source];
    NSString *meta = [NSString
        stringWithFormat:
            @"{\"kind\":\"自研草稿\",\"game\":\"%@\",\"bundle_id\":\"%@\","
             "\"version\":%ld,\"source\":\"%@\",\"need_verify\":true,"
             "\"user_overwrite\":false}\n",
            [self jsonEscape:self.gameName],
            [self jsonEscape:self.bundleId], (long)version,
            [self jsonEscape:pipelinePath ?: self.launcherPath ?: @""]];
    [AgentVersionStore writeCopyOnWrite:json body:meta];
  }
  self.lastResult = @{
    @"status" : wrote ? @"DRAFT_WRITTEN" : @"DRAFT_NOT_WRITTEN",
    @"phase" : @"P3",
    @"wrote_lua" : @(wrote),
    @"draft" : wrote ? draft : @"",
    @"pipeline_source" : pipelinePath ?: @"",
    @"previous" : before,
  };
  [self writeResultProbe:wrote ? @"draft_written" : @"draft_not_written"];
}

- (NSString *)pipelinePathFromSummary {
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_ai_pipeline.txt")
                                encoding:NSUTF8StringEncoding
                                   error:nil] ?: @"";
  for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"path="]) {
      NSString *path = [line substringFromIndex:5];
      if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return path;
      }
    }
  }
  return @"";
}

- (NSString *)luaQuote:(NSString *)value {
  NSString *s = value ?: @"";
  s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
  return [NSString stringWithFormat:@"\"%@\"", s];
}

- (NSString *)jsonEscape:(NSString *)value {
  NSString *s = value ?: @"";
  s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
  return s;
}

- (void)writeResultProbe:(NSString *)event {
  NSMutableDictionary *info =
      [NSMutableDictionary dictionaryWithDictionary:self.lastResult ?: @{}];
  info[@"event"] = event ?: @"";
  info[@"running"] = @(self.running);
  info[@"game"] = self.gameName ?: @"";
  info[@"bundle_id"] = self.bundleId ?: @"";
  info[@"launcher"] = self.launcherPath ?: @"";
  NSData *data = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [data writeToFile:ZiYanVarFile(@".ziyan_agent_gameplay.json")
          atomically:YES];
}

@end
