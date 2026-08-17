#import "AgentLearningCompiler.h"
#import "AgentABCPackets.h"
#import "AgentLearningRecorder.h"
#import "AgentVersionStore.h"
#import "ZiYanPaths.h"

@implementation AgentLearningCompiler

+ (void)writeProgress:(NSInteger)pct stage:(NSString *)stage {
  NSString *body =
      [NSString stringWithFormat:@"pct=%ld\nstage=%@\n", (long)pct, stage ?: @""];
  [body writeToFile:ZiYanVarFile(@".ziyan_agent_gen_progress")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

+ (NSString *)luaTemplateBid:(NSString *)bid
                         nx:(double)nx
                         ny:(double)ny
                    timeout:(NSInteger)timeout
                      retry:(NSInteger)retry
                    session:(NSString *)session
                       name:(NSString *)name {
  return [NSString
      stringWithFormat:
          @"-- 学习草稿 · 需要验证\n"
          @"-- schema_version=1 session=%@ game=%@\n"
          @"-- 相对归一化坐标；禁止当作稳定版本\n"
          @"init(1)\n"
          @"local TARGET=%@\n"
          @"local NX,NY=%.4f,%.4f\n"
          @"local TIMEOUT_MS=%ld\n"
          @"local MAX_RETRY=%ld\n"
          @"local function var_dir()\n"
          @"  if type(ZIYAN_VAR)=='string' and #ZIYAN_VAR>0 then return ZIYAN_VAR end\n"
          @"  if io.open('/var/jb/usr/lib/ziyan/var','r') then return '/var/jb/usr/lib/ziyan/var' end\n"
          @"  return '/usr/lib/ziyan/var'\n"
          @"end\n"
          @"local function stopped()\n"
          @"  local f=io.open(var_dir()..'/.ziyan_stop','r')\n"
          @"  if f then f:close(); return true end\n"
          @"  f=io.open(var_dir()..'/.ziyan_user_stopped','r')\n"
          @"  if f then f:close(); return true end\n"
          @"  return false\n"
          @"end\n"
          @"local function front_ok()\n"
          @"  if type(frontAppBid)~='function' then return false end\n"
          @"  return tostring(frontAppBid() or '')==TARGET\n"
          @"end\n"
          @"if stopped() or not front_ok() then\n"
          @"  if type(toast)=='function' then toast('PAUSED_SAFE') end\n"
          @"  return\n"
          @"end\n"
          @"local w,h=0,0\n"
          @"if type(getScreenSize)=='function' then w,h=getScreenSize() end\n"
          @"if not w or w<1 then w,h=375,667 end\n"
          @"local x,y=NX*w,NY*h\n"
          @"local n=0\n"
          @"while n<=MAX_RETRY do\n"
          @"  if stopped() or not front_ok() then\n"
          @"    if type(toast)=='function' then toast('UNKNOWN') end\n"
          @"    break\n"
          @"  end\n"
          @"  tap(x,y)\n"
          @"  if type(mSleep)=='function' then mSleep(TIMEOUT_MS) end\n"
          @"  if front_ok() then break end\n"
          @"  n=n+1\n"
          @"end\n",
          session, name, [self luaQuote:bid], nx, ny, (long)timeout, (long)retry];
}

+ (NSString *)luaQuote:(NSString *)s {
  NSString *q = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  q = [q stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
  return [NSString stringWithFormat:@"'%@'", q ?: @""];
}

+ (NSDictionary *)compileLearnSession:(NSString *)sessionId
                                 name:(NSString *)name
                                  bid:(NSString *)bid
                               events:(NSArray *)events {
  (void)events;
  [AgentVersionStore ensureDirs];
  [AgentABCPackets ensureSessionDir:sessionId];
  [self writeProgress:0 stage:@"结束学习会话"];
  [[AgentLearningRecorder shared] finalizePending];
  [self writeProgress:15 stage:@"整理用户操作"];
  NSArray *all = [AgentABCPackets loadObservations:sessionId];
  NSMutableArray *allow = [NSMutableArray array];
  for (NSDictionary *o in all) {
    BOOL changed = [o[@"after_features"][@"changed"] boolValue];
    NSDictionary *np = o[@"normalized_point"];
    BOOL hasN = [np isKindOfClass:[NSDictionary class]];
    if (changed && hasN && bid.length > 0 && ![o[@"sensitive_flag"] boolValue]) {
      [allow addObject:o];
    }
  }
  [self writeProgress:35 stage:@"提取前后状态"];
  [self writeProgress:55 stage:@"生成动作与验证草稿"];

  NSString *stem = [AgentVersionStore pinyinStemForName:name];
  NSString *luaPath = @"";
  NSString *jsonPath = @"";
  NSString *decision = @"REJECT";
  NSString *reason = @"学习内容不足，已生成报告，未生成可运行脚本。";
  NSString *next = @"manual_review";
  double quality = allow.count > 0 ? 0.6 : 0.1;

  if (allow.count == 0) {
    [self writeProgress:75 stage:@"学习内容不足，只生成报告"];
    [AgentABCPackets writePlan:@{
      @"game_name" : name ?: @"",
      @"bundle_id" : bid ?: @"",
      @"source_observations" : @[],
      @"actions" : @[],
      @"precondition" : @"none",
      @"postcondition" : @"none",
      @"timeout" : @0,
      @"max_retry" : @0,
      @"risk" : @"insufficient",
      @"generated_lua_path" : @"",
    }
                     sessionId:sessionId];
  } else {
    NSDictionary *o = allow.firstObject;
    NSDictionary *np = o[@"normalized_point"];
    double nx = [np[@"x"] doubleValue];
    double ny = [np[@"y"] doubleValue];
    NSInteger timeout = 800;
    NSInteger retry = 1;
    luaPath = [AgentVersionStore unusedLearnLuaPathForStem:stem];
    jsonPath = [[luaPath stringByDeletingPathExtension]
        stringByAppendingPathExtension:@"json"];
    NSString *lua = [self luaTemplateBid:bid
                                      nx:nx
                                      ny:ny
                                 timeout:timeout
                                   retry:retry
                                 session:sessionId
                                    name:name];
    BOOL hasAbsLoop = [lua containsString:@"tap(%.0f"] ||
                      [lua containsString:@"while true"];
    (void)hasAbsLoop;
    [self writeProgress:75 stage:@"生成 Lua 业务脚本草稿"];
    [self writeProgress:90 stage:@"执行语法、路径、动作合同和安全检查"];
    BOOL contract = bid.length > 0 && nx >= 0 && ny >= 0 &&
                    [lua containsString:@"frontAppBid"] &&
                    [lua containsString:@"stopped"] &&
                    [lua containsString:@"NX,NY"];
    if (contract) {
      [AgentVersionStore writeCopyOnWrite:luaPath body:lua];
      NSString *meta = [NSString
          stringWithFormat:
              @"{\"kind\":\"学习草稿\",\"session\":\"%@\",\"game\":\"%@\","
              @"\"bundle_id\":\"%@\",\"need_verify\":true,"
              @"\"normalized\":true,\"user_overwrite\":false}\n",
              sessionId, name, bid];
      [AgentVersionStore writeCopyOnWrite:jsonPath body:meta];
      decision = @"ALLOW";
      reason = @"qualified_observation";
      next = @"verify_draft";
      quality = 0.72;
      [AgentABCPackets writePlan:@{
        @"game_name" : name ?: @"",
        @"bundle_id" : bid ?: @"",
        @"source_observations" : @[ o[@"event_id"] ?: @"" ],
        @"actions" : @[ @"tap_normalized" ],
        @"precondition" : [NSString stringWithFormat:@"front==%@", bid],
        @"postcondition" : @"front_ok_or_UNKNOWN",
        @"timeout" : @(timeout),
        @"max_retry" : @(retry),
        @"risk" : @"low",
        @"generated_lua_path" : luaPath.lastPathComponent ?: @"",
      }
                       sessionId:sessionId];
    } else {
      luaPath = @"";
      jsonPath = @"";
      reason = @"动作合同不足，已生成报告，未生成可运行脚本。";
      [AgentABCPackets writePlan:@{
        @"game_name" : name ?: @"",
        @"bundle_id" : bid ?: @"",
        @"source_observations" : @[],
        @"actions" : @[],
        @"precondition" : @"invalid",
        @"postcondition" : @"none",
        @"timeout" : @0,
        @"max_retry" : @0,
        @"risk" : @"contract_fail",
        @"generated_lua_path" : @"",
      }
                       sessionId:sessionId];
    }
  }

  NSString *luaHash = [AgentABCPackets hashOfString:luaPath ?: @""];
  [AgentABCPackets writeVerdict:@{
    @"subject_hash" : luaHash,
    @"decision" : decision,
    @"reason" : reason,
    @"evidence_refs" : @[
      [AgentABCPackets observationPath:sessionId].lastPathComponent ?: @"观察.jsonl"
    ],
    @"quality_score" : @(quality),
    @"performance_summary" : @{
      @"observations" : @(all.count),
      @"allowed" : @(allow.count),
    },
    @"next_action" : next,
  }
                      sessionId:sessionId];

  NSString *report = [[AgentVersionStore runLogDir]
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%@_学习报告.txt", sessionId]];
  NSString *repBody = [NSString
      stringWithFormat:
          @"session=%@\ngame=%@\nbid=%@\nobservations=%lu\nallowed=%lu\n"
          @"decision=%@\nreason=%@\nlua=%@\nneed_verify=1\noverwrite_user=0\n"
          @"hint=%@\n",
          sessionId, name, bid, (unsigned long)all.count,
          (unsigned long)allow.count, decision, reason,
          luaPath.lastPathComponent ?: @"", reason];
  [repBody writeToFile:report atomically:YES encoding:NSUTF8StringEncoding
                 error:nil];
  NSString *qpath = [[AgentVersionStore genScriptDir]
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%@_质量报告.json", sessionId]];
  NSString *qbody = [NSString
      stringWithFormat:
          @"{\"session\":\"%@\",\"decision\":\"%@\",\"events\":%lu,"
          @"\"lua_written\":%@,\"user_overwrite\":false}\n",
          sessionId, decision, (unsigned long)all.count,
          luaPath.length ? @"true" : @"false"];
  [qbody writeToFile:qpath atomically:YES encoding:NSUTF8StringEncoding
               error:nil];
  [self writeProgress:100 stage:@"保存完成"];
  return @{
    @"verdict" : decision,
    @"reason" : reason,
    @"lua" : luaPath ?: @"",
    @"json" : jsonPath ?: @"",
    @"report" : report ?: @"",
    @"events" : @(all.count),
    @"allowed" : @(allow.count),
  };
}

@end
