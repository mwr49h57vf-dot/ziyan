#import "ZiYanDefenseAI.h"
#import "ZiYanDefense.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>

/*
  模型集成策略（诚实约束）：
  - 文档指定 3 个 HF 分类器体积/依赖不适合直接打进 iPhone7/8 的 deb。
  - 默认：本地启发式评分（规则来自 ios_re_jb_detection / game-security 检测面）。
  - 可选：若 Media/ZiYan/models/ 下存在 onnx 权重且设备已装 onnxruntime，则尝试加载
    （本仓库不捆绑权重；见 tools/ziyan_defense/fetch_models.sh，需你确认后再拉）。
*/

@interface ZiYanDefenseAI ()
@property(nonatomic, strong, nullable) dispatch_source_t timer;
@property(nonatomic, assign) float lastConfidence;
@property(nonatomic, assign) BOOL analyzing;
@property(nonatomic, assign) NSTimeInterval analyzeUntil;
@property(nonatomic, copy, nullable) NSString *lastEvidence;
@end

@implementation ZiYanDefenseAI

+ (instancetype)shared {
  static ZiYanDefenseAI *o;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    o = [[ZiYanDefenseAI alloc] init];
  });
  return o;
}

/// 扫描 Media/ZiYan/models 三套 HF 权重是否落地（不在真机跑满 Transformer）
- (NSInteger)inventoryHFModelsWriteStatus:(BOOL)write {
  NSString *models = ZiYanModelsDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  // 兼容旧路径 Media/ZiYan/models
  if (![fm fileExistsAtPath:models]) {
    NSString *legacy =
        [[ZiYanDefense mediaZiYanDir] stringByAppendingPathComponent:@"models"];
    if ([fm fileExistsAtPath:legacy]) {
      models = legacy;
    }
  }
  NSArray *checks = @[
    @[
      @"ynyg__Unified_Prompt_Guard", @"model.safetensors", @"config.json"
    ],
    @[
      @"vincentoh__jailbreak-detector-v5", @"adapter_model.safetensors",
      @"adapter_config.json"
    ],
    @[
      @"llm-semantic-router__mmbert-jailbreak-detector-merged",
      @"model.safetensors", @"config.json"
    ],
  ];
  NSMutableString *st = [NSMutableString stringWithString:@"stage=6\n"];
  NSInteger ready = 0;
  for (NSArray *c in checks) {
    NSString *dir = c[0];
    NSString *weight = c[1];
    NSString *cfg = c[2];
    NSString *base = [models stringByAppendingPathComponent:dir];
    BOOL wOK = [fm fileExistsAtPath:[base stringByAppendingPathComponent:weight]];
    BOOL cOK = [fm fileExistsAtPath:[base stringByAppendingPathComponent:cfg]];
    // 兼容旧探测名
    if (!cOK) {
      cOK = [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"config.json"]];
    }
    BOOL ok = wOK && cOK;
    if (ok) {
      ready++;
    }
    unsigned long long sz = 0;
    if (wOK) {
      NSDictionary *attr = [fm attributesOfItemAtPath:[base
          stringByAppendingPathComponent:weight]
                                                 error:nil];
      sz = [attr fileSize];
    }
    [st appendFormat:@"%@=%@ weight=%@ cfg=%@ bytes=%llu\n", dir,
                     ok ? @"READY" : @"MISS", wOK ? @"1" : @"0",
                     cOK ? @"1" : @"0", sz];
  }
  [st appendFormat:@"ready_count=%ld/3\n", (long)ready];
  [st appendString:@"runtime=heuristic+weight_presence\n"];
  if (write) {
    NSString *path = [models stringByAppendingPathComponent:@"models_status.txt"];
    [fm createDirectoryAtPath:models
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    [st writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // 兼容阶段验收
    NSString *readyPath =
        [models stringByAppendingPathComponent:@"MODELS_READY.txt"];
    if (ready >= 3) {
      [@"stage=6\nmodels=3\nall_ready=1\n" writeToFile:readyPath
                                            atomically:YES
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    }
    [self appendDefenseLog:[NSString stringWithFormat:@"hf_models ready=%ld/3",
                                                      (long)ready]];
  }
  return ready;
}

- (float)scoreEvidence:(NSString *)ev {
  if (ev.length == 0) {
    return 0;
  }
  float s = 0.15f;
  NSString *l = ev.lowercaseString;
  NSArray *hot = @[
    @"sysctl", @"uname", @"dyld", @"image", @"private", @"iokit", @"bypass",
    @"frida", @"needle", @"substrate", @"hook", @"fingerprint", @"idfv",
    @"stat(/var/jb", @"mobilesubstrate"
  ];
  for (NSString *h in hot) {
    if ([l containsString:h]) {
      s += 0.12f;
    }
  }
  if (s > 0.99f) {
    s = 0.99f;
  }
  // 三模型权重在位 → 小幅抬升（真机默认启发式；完整推理需 PC/侧车）
  NSInteger present = [self inventoryHFModelsWriteStatus:NO];
  if (present > 0) {
    s = MIN(0.99f, s + 0.05f * (float)MIN(present, 3));
  }
  return s;
}

- (void)appendDefenseLog:(NSString *)msg {
  NSString *path = [ZiYanDefense defenseLogPath];
  NSString *line = [NSString
      stringWithFormat:@"ts=%lld ai %@\n",
                       (long long)([[NSDate date] timeIntervalSince1970] *
                                   1000.0),
                       msg];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  [fh seekToEndOfFile];
  [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
}

- (void)startMonitoring {
  if (self.timer) {
    return;
  }
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
  self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(5.0 * NSEC_PER_SEC),
                            (uint64_t)(0.5 * NSEC_PER_SEC));
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(self.timer, ^{
    ZiYanDefenseAI *s = weakSelf;
    if (!s) {
      return;
    }
    // 轮询验收触发文件
    NSString *trig = [[ZiYanDefense defenseResDir]
        stringByAppendingPathComponent:@"defense_bypass_trig.txt"];
    NSString *body =
        [NSString stringWithContentsOfFile:trig
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (body.length > 0) {
      [[NSFileManager defaultManager] removeItemAtPath:trig error:nil];
      NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
      [s ingestBypassEvidence:body bundleId:bid];
    }
    // 验收：写 defense_shutdown_trig → 恢复真实环境（删指纹 + clean）
    NSString *shut = [[ZiYanDefense defenseResDir]
        stringByAppendingPathComponent:@"defense_shutdown_trig"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:shut]) {
      [[NSFileManager defaultManager] removeItemAtPath:shut error:nil];
      [[ZiYanDefense shared] shutdownAndRestore];
      [s appendDefenseLog:@"shutdown_trig → restore"];
    }
    if (s.analyzing &&
        [[NSDate date] timeIntervalSince1970] > s.analyzeUntil) {
      s.analyzing = NO;
      [s appendDefenseLog:@"analyze_timeout → release"];
    }
  });
  dispatch_resume(self.timer);
  [self appendDefenseLog:@"monitor_start"];
  // 阶段6：启动时盘点 HF 三模型权重落地情况
  (void)[self inventoryHFModelsWriteStatus:YES];
}

- (void)stopMonitoring {
  if (self.timer) {
    dispatch_source_cancel(self.timer);
    self.timer = nil;
  }
  [self appendDefenseLog:@"monitor_stop"];
}

- (void)ingestBypassEvidence:(NSString *)evidence bundleId:(NSString *)bid {
  self.lastEvidence = [evidence copy] ?: @"";
  self.analyzing = YES;
  self.analyzeUntil = [[NSDate date] timeIntervalSince1970] + 10.0;
  float conf = [self scoreEvidence:evidence];
  self.lastConfidence = conf;
  [self appendDefenseLog:[NSString
                             stringWithFormat:@"bypass bid=%@ conf=%.2f ev=%@",
                                              bid, conf,
                                              evidence.length > 120
                                                  ? [evidence substringToIndex:120]
                                                  : evidence]];
  if (conf > 0.85f) {
    [self appendDefenseLog:@"verdict=BREAK_DEFENSE → harden"];
    NSString *mark = [[ZiYanDefense defenseResDir]
        stringByAppendingPathComponent:@"defense_break.flag"];
    [@"1\n" writeToFile:mark atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // 同步写出 defer toast 文件，便于双机验收不依赖进程退出路径
    (void)[self shouldDeferExitWithToast];
  } else {
    [self appendDefenseLog:@"verdict=watch"];
  }
}

- (BOOL)shouldDeferExitWithToast {
  if (!self.analyzing) {
    return NO;
  }
  // Toast 必须在主线程；防御层通过写 cmd 让 SB ToastBridge 显示（若可用）
  NSString *cmd = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_cmd"];
  // toast 文件协议：两行 text + duration（与 ToastBridge 现有解析兼容则用之）
  // 若不在 SB，则仅写 defense 提示文件
  NSString *tip = [[ZiYanDefense defenseResDir]
      stringByAppendingPathComponent:@"defense_exit_toast.txt"];
  NSString *msg = @"游戏突破自身防御，等待分析结束恢复";
  [msg writeToFile:tip atomically:YES encoding:NSUTF8StringEncoding error:nil];
  // 尝试走全局 toast（SpringBoard 侧监听时生效）
  NSString *body =
      [NSString stringWithFormat:@"%@\n1200\n", msg];
  [body writeToFile:cmd atomically:YES encoding:NSUTF8StringEncoding error:nil];
  [self appendDefenseLog:@"defer_exit toast_requested"];
  return YES;
}

@end
