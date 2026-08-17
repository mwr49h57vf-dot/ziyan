#import "AgentABCPackets.h"
#import "AgentVersionStore.h"
#import "ZiYanPaths.h"

@implementation AgentABCPackets

+ (NSString *)sessionDir:(NSString *)sessionId {
  NSString *sid = sessionId.length ? sessionId : @"unknown";
  return [[[AgentVersionStore agentRoot] stringByAppendingPathComponent:@"会话"]
      stringByAppendingPathComponent:sid];
}

+ (void)ensureSessionDir:(NSString *)sessionId {
  [AgentVersionStore ensureDirs];
  [[NSFileManager defaultManager]
      createDirectoryAtPath:[self sessionDir:sessionId]
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0755}
                            error:nil];
}

+ (NSString *)hashOfString:(NSString *)s {
  NSUInteger h = 2166136261u;
  const char *c = (s ?: @"").UTF8String;
  if (c) {
    while (*c) {
      h ^= (unsigned char)*c++;
      h *= 16777619u;
    }
  }
  return [NSString stringWithFormat:@"%08lx", (unsigned long)h];
}

+ (NSString *)observationPath:(NSString *)sessionId {
  return [[self sessionDir:sessionId] stringByAppendingPathComponent:@"观察.jsonl"];
}

+ (NSString *)planPath:(NSString *)sessionId {
  return [[self sessionDir:sessionId]
      stringByAppendingPathComponent:@"计划候选.json"];
}

+ (NSString *)verdictPath:(NSString *)sessionId {
  return [[self sessionDir:sessionId]
      stringByAppendingPathComponent:@"审核结论.json"];
}

+ (NSDictionary *)stamp:(NSMutableDictionary *)d {
  d[@"schema_version"] = @1;
  d[@"created_at"] =
      @((long long)[[NSDate date] timeIntervalSince1970] * 1000);
  NSData *raw = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil]
                    ?: [NSData data];
  NSString *body = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding]
                       ?: @"";
  d[@"hash"] = [self hashOfString:body];
  return d;
}

+ (NSDictionary *)appendObservation:(NSDictionary *)obs
                          sessionId:(NSString *)sessionId {
  [self ensureSessionDir:sessionId];
  NSMutableDictionary *d = [obs mutableCopy] ?: [NSMutableDictionary dictionary];
  d[@"session_id"] = sessionId ?: @"";
  [self stamp:d];
  NSData *raw = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil]
                    ?: [NSData data];
  NSString *json =
      [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding] ?: @"";
  NSString *line = [json stringByAppendingString:@"\n"];
  NSString *path = [self observationPath:sessionId];
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!h) {
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  } else {
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
  }
  return d;
}

+ (NSDictionary *)writePlan:(NSDictionary *)plan
                  sessionId:(NSString *)sessionId {
  [self ensureSessionDir:sessionId];
  NSMutableDictionary *d = [plan mutableCopy] ?: [NSMutableDictionary dictionary];
  d[@"session_id"] = sessionId ?: @"";
  d[@"source_session"] = sessionId ?: @"";
  [self stamp:d];
  NSData *raw = [NSJSONSerialization dataWithJSONObject:d
                                                options:NSJSONWritingPrettyPrinted
                                                  error:nil];
  [raw writeToFile:[self planPath:sessionId] atomically:YES];
  return d;
}

+ (NSDictionary *)writeVerdict:(NSDictionary *)verdict
                     sessionId:(NSString *)sessionId {
  [self ensureSessionDir:sessionId];
  NSMutableDictionary *d =
      [verdict mutableCopy] ?: [NSMutableDictionary dictionary];
  d[@"session_id"] = sessionId ?: @"";
  [self stamp:d];
  NSData *raw = [NSJSONSerialization dataWithJSONObject:d
                                                options:NSJSONWritingPrettyPrinted
                                                  error:nil];
  [raw writeToFile:[self verdictPath:sessionId] atomically:YES];
  return d;
}

+ (NSArray *)loadObservations:(NSString *)sessionId {
  NSString *raw =
      [NSString stringWithContentsOfFile:[self observationPath:sessionId]
                                encoding:NSUTF8StringEncoding
                                   error:nil]
          ?: @"";
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
    if (line.length < 8) {
      continue;
    }
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
      [out addObject:obj];
    }
  }
  return out;
}

@end
