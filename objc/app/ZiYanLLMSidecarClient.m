#import "ZiYanLLMSidecarClient.h"
#import "ZiYanPaths.h"
#import <sys/stat.h>
#import <unistd.h>

@implementation ZiYanLLMSidecarClient

+ (NSString *)mediaRoot {
  return ZiYanScriptsDirectory();
}

+ (NSString *)sidecarBaseURL {
  // 可选：Media/ZiYan/.ziyan_sidecar_url 一行，如 http://192.168.31.x:8765
  NSArray *cands = @[
    [[self mediaRoot] stringByAppendingPathComponent:@".ziyan_sidecar_url"],
    @"/private/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_sidecar_url",
    @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_sidecar_url",
    @"/private/var/mobile/Media/ZiYan/.ziyan_sidecar_url",
    @"/var/mobile/Media/ZiYan/.ziyan_sidecar_url",
  ];
  for (NSString *p in cands) {
    NSString *t = [[NSString stringWithContentsOfFile:p
                                             encoding:NSUTF8StringEncoding
                                                error:nil]
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if ([t hasPrefix:@"http://"] || [t hasPrefix:@"https://"]) {
      if ([t hasSuffix:@"/"]) {
        return [t substringToIndex:t.length - 1];
      }
      return t;
    }
  }
  return @"http://127.0.0.1:8765";
}

+ (BOOL)modelsReadyWant:(NSInteger)want statusOut:(NSString **)statusOut {
  NSArray *cands = @[
    [[self mediaRoot] stringByAppendingPathComponent:@"models/models_status.txt"],
    @"/private/var/mobile/Media/ZiYan/ZYCV/res/models/models_status.txt",
    @"/var/mobile/Media/ZiYan/ZYCV/res/models/models_status.txt",
    @"/private/var/mobile/Media/ZiYan/models/models_status.txt",
    @"/var/mobile/Media/ZiYan/models/models_status.txt",
  ];
  NSString *body = @"";
  for (NSString *path in cands) {
    NSString *t = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
    if (t.length) {
      body = t;
      break;
    }
  }
  if (statusOut) {
    *statusOut = body;
  }
  NSInteger ready = 0;
  NSRegularExpression *re =
      [NSRegularExpression regularExpressionWithPattern:@"ready_count\\s*=\\s*(\\d+)"
                                                options:0
                                                  error:nil];
  NSTextCheckingResult *m =
      [re firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
  if (m && m.numberOfRanges > 1) {
    ready = [[body substringWithRange:[m rangeAtIndex:1]] integerValue];
  } else if ([body localizedCaseInsensitiveContainsString:@"READY"]) {
    for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
      if ([line localizedCaseInsensitiveContainsString:@"READY"]) {
        ready++;
      }
    }
  }
  return ready >= want;
}

+ (BOOL)writeJSON:(NSDictionary *)obj toPath:(NSString *)path error:(NSString **)errOut {
  NSError *e = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&e];
  if (!data) {
    if (errOut)
      *errOut = e.localizedDescription ?: @"json_encode_fail";
    return NO;
  }
  [[NSFileManager defaultManager]
            createDirectoryAtPath:[path stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  if (![data writeToFile:path atomically:YES]) {
    if (errOut)
      *errOut = @"write_fail";
    return NO;
  }
  chmod(path.fileSystemRepresentation, 0666);
  return YES;
}

+ (nullable NSDictionary *)readJSON:(NSString *)path {
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data.length) {
    return nil;
  }
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

/// POST /v1/... ；失败返回 nil（调用方回退文件投递）
+ (nullable NSDictionary *)httpPostPath:(NSString *)apiPath
                                   body:(NSDictionary *)body
                            timeoutSec:(NSTimeInterval)timeoutSec
                                 error:(NSString **)errOut {
  NSString *urlStr =
      [NSString stringWithFormat:@"%@%@", [self sidecarBaseURL], apiPath];
  NSURL *url = [NSURL URLWithString:urlStr];
  if (!url) {
    if (errOut)
      *errOut = @"bad_sidecar_url";
    return nil;
  }
  NSError *je = nil;
  NSData *payload =
      [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:&je];
  if (!payload) {
    if (errOut)
      *errOut = je.localizedDescription ?: @"json_encode_fail";
    return nil;
  }
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = payload;
  req.timeoutInterval = MIN(MAX(timeoutSec, 2.0), 25.0);

  __block NSData *respData = nil;
  __block NSHTTPURLResponse *http = nil;
  __block NSError *netErr = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          respData = data;
          http = (NSHTTPURLResponse *)response;
          netErr = error;
          dispatch_semaphore_signal(sem);
        }];
  [task resume];
  long wait = dispatch_semaphore_wait(
      sem, dispatch_time(DISPATCH_TIME_NOW,
                         (int64_t)((timeoutSec + 1.0) * NSEC_PER_SEC)));
  if (wait != 0) {
    [task cancel];
    if (errOut)
      *errOut = @"http_timeout";
    return nil;
  }
  if (netErr || http.statusCode < 200 || http.statusCode >= 300 ||
      respData.length == 0) {
    if (errOut)
      *errOut = netErr.localizedDescription
                    ?: [NSString stringWithFormat:@"http_status_%ld",
                                                  (long)http.statusCode];
    return nil;
  }
  id obj = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
  if (![obj isKindOfClass:[NSDictionary class]]) {
    if (errOut)
      *errOut = @"http_bad_json";
    return nil;
  }
  return obj;
}

+ (nullable NSDictionary *)pollResultPath:(NSString *)resultPath
                              timeoutSec:(NSTimeInterval)timeoutSec
                                   error:(NSString **)errOut {
  NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + timeoutSec;
  [[NSFileManager defaultManager] removeItemAtPath:resultPath error:nil];
  while (NSDate.date.timeIntervalSince1970 < deadline) {
    NSDictionary *r = [self readJSON:resultPath];
    if (r) {
      return r;
    }
    [NSThread sleepForTimeInterval:0.4];
  }
  if (errOut) {
    *errOut = @"sidecar_timeout_no_result";
  }
  return nil;
}

+ (nullable NSDictionary *)runScriptGen:(NSDictionary *)req
                            timeoutSec:(NSTimeInterval)timeoutSec
                                 error:(NSString **)errOut {
  NSMutableDictionary *body = [req mutableCopy] ?: [NSMutableDictionary dictionary];
  body[@"action"] = @"scriptgen";
  body[@"ts"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0));

  // 1) HTTP POST /v1/scriptgen/run
  NSString *httpErr = nil;
  NSDictionary *httpRes =
      [self httpPostPath:@"/v1/scriptgen/run"
                    body:body
             timeoutSec:MAX(8.0, MIN(timeoutSec, 25.0))
                  error:&httpErr];
  if ([httpRes[@"ok"] boolValue] ||
      ([httpRes[@"lua"] isKindOfClass:[NSString class]] &&
       [httpRes[@"lua"] length] > 32)) {
    NSMutableDictionary *ok = [httpRes mutableCopy];
    ok[@"via"] = @"http";
    return ok;
  }

  // 2) 文件投递回退
  NSString *reqPath =
      [[self mediaRoot] stringByAppendingPathComponent:@"scriptgen_req.json"];
  NSString *resPath =
      [[self mediaRoot] stringByAppendingPathComponent:@"scriptgen_result.json"];
  if (![self writeJSON:body toPath:reqPath error:errOut]) {
    return nil;
  }
  NSString *fileErr = nil;
  NSDictionary *fileRes =
      [self pollResultPath:resPath timeoutSec:timeoutSec error:&fileErr];
  if (fileRes) {
    NSMutableDictionary *ok = [fileRes mutableCopy];
    ok[@"via"] = @"file";
    return ok;
  }
  if (errOut) {
    *errOut = fileErr ?: httpErr ?: @"sidecar_unavailable";
  }
  return nil;
}

+ (nullable NSDictionary *)runDumpAnalyze:(NSDictionary *)req
                              timeoutSec:(NSTimeInterval)timeoutSec
                                   error:(NSString **)errOut {
  NSMutableDictionary *body = [req mutableCopy] ?: [NSMutableDictionary dictionary];
  body[@"action"] = @"dump_analyze";
  body[@"ts"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0));

  NSString *httpErr = nil;
  NSDictionary *httpRes =
      [self httpPostPath:@"/v1/dump_analyze/run"
                    body:body
             timeoutSec:MIN(timeoutSec, 8.0)
                  error:&httpErr];
  if ([httpRes[@"ok"] boolValue] ||
      [httpRes[@"report_md"] isKindOfClass:[NSString class]] ||
      [httpRes[@"report_json"] isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *ok = [httpRes mutableCopy];
    ok[@"via"] = @"http";
    return ok;
  }

  NSString *reqPath =
      [[self mediaRoot] stringByAppendingPathComponent:@"dump_analyze_req.json"];
  NSString *resPath = [[self mediaRoot]
      stringByAppendingPathComponent:@"dump_analyze_result.json"];
  if (![self writeJSON:body toPath:reqPath error:errOut]) {
    return nil;
  }
  NSString *fileErr = nil;
  NSDictionary *fileRes =
      [self pollResultPath:resPath timeoutSec:timeoutSec error:&fileErr];
  if (fileRes) {
    NSMutableDictionary *ok = [fileRes mutableCopy];
    ok[@"via"] = @"file";
    return ok;
  }
  if (errOut) {
    *errOut = fileErr ?: httpErr ?: @"sidecar_unavailable";
  }
  return nil;
}

+ (nullable NSDictionary *)runVisionAnalyze:(NSDictionary *)req
                                timeoutSec:(NSTimeInterval)timeoutSec
                                     error:(NSString **)errOut {
  NSMutableDictionary *body = [req mutableCopy] ?: [NSMutableDictionary dictionary];
  body[@"action"] = @"vision_analyze";
  body[@"ts"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0));

  NSString *httpErr = nil;
  NSDictionary *httpRes =
      [self httpPostPath:@"/v1/vision/analyze"
                    body:body
             timeoutSec:MAX(6.0, MIN(timeoutSec, 20.0))
                  error:&httpErr];
  if ([httpRes[@"ok"] boolValue] ||
      [httpRes[@"colors"] isKindOfClass:[NSArray class]]) {
    NSMutableDictionary *ok = [httpRes mutableCopy];
    ok[@"via"] = @"http";
    return ok;
  }

  NSString *reqPath =
      [[self mediaRoot] stringByAppendingPathComponent:@"vision_analyze_req.json"];
  NSString *resPath = [[self mediaRoot]
      stringByAppendingPathComponent:@"vision_analyze_result.json"];
  if (![self writeJSON:body toPath:reqPath error:errOut]) {
    return nil;
  }
  NSString *fileErr = nil;
  NSDictionary *fileRes =
      [self pollResultPath:resPath timeoutSec:timeoutSec error:&fileErr];
  if (fileRes) {
    NSMutableDictionary *ok = [fileRes mutableCopy];
    ok[@"via"] = @"file";
    return ok;
  }
  if (errOut) {
    *errOut = fileErr ?: httpErr ?: @"vision_sidecar_unavailable";
  }
  // 侧车不可用：本地回传 colors（调用方已采样）
  return @{
    @"ok" : @YES,
    @"via" : @"local_passthrough",
    @"colors" : body[@"colors"] ?: @[],
    @"models_combined" : @NO,
  };
}

@end
