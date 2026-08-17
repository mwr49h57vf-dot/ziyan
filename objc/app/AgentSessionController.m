#import "AgentSessionController.h"
#import "AgentABCPackets.h"
#import "AgentLearningRecorder.h"
#import "AgentLearningCompiler.h"
#import "AgentAutonomousEngine.h"
#import "AgentVersionStore.h"
#import "ZiYanHomeViewController.h"
#import "ZiYanPaths.h"
#import "ZiYanAppSelector.h"
#import <UIKit/UIKit.h>

@interface AgentSessionController ()
@property (nonatomic, assign) AgentUIState uiState;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, copy) NSString *lastReason;
@property (nonatomic, assign) BOOL polling;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, assign) NSTimeInterval waitingSince;
@property (nonatomic, assign) NSInteger pendingLockHits;
@property (nonatomic, copy) NSString *pendingLockBid;
@end

@implementation AgentSessionController

+ (instancetype)shared {
  static AgentSessionController *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[AgentSessionController alloc] init];
    s.uiState = AgentUIIdle;
    s.displayName = @"";
    s.bundleId = @"";
    s.sessionId = @"";
    s.mode = @"";
    s.lastReason = @"init";
    s.bgTask = UIBackgroundTaskInvalid;
    s.waitingSince = 0;
    s.pendingLockHits = 0;
    s.pendingLockBid = @"";
    [s recoverStaleSession];
  });
  return s;
}

- (void)beginBgTask {
  if (self.bgTask != UIBackgroundTaskInvalid) {
    return;
  }
  __weak typeof(self) weakSelf = self;
  self.bgTask = [[UIApplication sharedApplication]
      beginBackgroundTaskWithName:@"ziyan.agent.session"
                expirationHandler:^{
                  AgentSessionController *me = weakSelf;
                  if (!me) {
                    return;
                  }
                  if (me.uiState == AgentUIWaitingLock ||
                      me.uiState == AgentUILearning ||
                      me.uiState == AgentUIExploring ||
                      me.uiState == AgentUIIterating) {
                    [me transitTo:AgentUIPausedSafe reason:@"bg_expired"];
                  }
                  [me endBgTask];
                }];
}

- (void)endBgTask {
  if (self.bgTask == UIBackgroundTaskInvalid) {
    return;
  }
  [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
  self.bgTask = UIBackgroundTaskInvalid;
}

- (NSString *)stateCode:(AgentUIState)st {
  switch (st) {
  case AgentUIWaitingLock:
    return @"WAITING_LOCK";
  case AgentUILearning:
    return @"LEARNING";
  case AgentUIGenerating:
    return @"GENERATING";
  case AgentUIExploring:
    return @"EXPLORING";
  case AgentUIIterating:
    return @"ITERATING";
  case AgentUIPausedSafe:
    return @"PAUSED_SAFE";
  case AgentUICompleted:
    return @"COMPLETED";
  case AgentUICancelled:
    return @"CANCELLED";
  default:
    return @"IDLE";
  }
}

- (NSString *)uiStateText {
  switch (self.uiState) {
  case AgentUIWaitingLock:
    return @"等待锁定游戏";
  case AgentUILearning:
    return @"学习中";
  case AgentUIGenerating:
    return @"生成中";
  case AgentUIExploring:
    return @"自主探索中";
  case AgentUIIterating:
    return @"迭代运行中";
  case AgentUIPausedSafe:
    return @"安全暂停";
  case AgentUICompleted:
    return @"已完成";
  case AgentUICancelled:
    return @"已取消";
  default:
    return @"未运行";
  }
}

- (BOOL)isActive {
  return self.uiState == AgentUIWaitingLock ||
         self.uiState == AgentUILearning ||
         self.uiState == AgentUIGenerating ||
         self.uiState == AgentUIExploring ||
         self.uiState == AgentUIIterating;
}

- (BOOL)acceptsVolumeStop {
  return self.isActive || self.uiState == AgentUIPausedSafe;
}

- (void)appendTransitFrom:(AgentUIState)prev
                       to:(AgentUIState)next
                   reason:(NSString *)reason {
  if (self.sessionId.length == 0) {
    return;
  }
  [AgentABCPackets ensureSessionDir:self.sessionId];
  long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
  NSString *line = [NSString
      stringWithFormat:
          @"{\"session_id\":\"%@\",\"mode\":\"%@\",\"bundle_id\":\"%@\","
          @"\"display_name\":\"%@\",\"previous_state\":\"%@\","
          @"\"next_state\":\"%@\",\"reason\":\"%@\",\"active\":%d,\"ts\":%lld}\n",
          self.sessionId ?: @"", self.mode ?: @"", self.bundleId ?: @"",
          self.displayName ?: @"", [self stateCode:prev], [self stateCode:next],
          reason ?: @"", [self isActive] ? 1 : 0, ts];
  NSString *path = [[AgentABCPackets sessionDir:self.sessionId]
      stringByAppendingPathComponent:@"状态迁移.jsonl"];
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!h) {
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  } else {
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
  }
}

- (void)writeSession {
  NSString *body = [NSString
      stringWithFormat:
          @"state=%@\nui_state=%@\nsession_id=%@\nmode=%@\n"
          @"bundle_id=%@\ndisplay_name=%@\nactive=%d\nreason=%@\n"
          @"ts=%lld\n",
          [self stateCode:self.uiState], [self uiStateText],
          self.sessionId ?: @"", self.mode ?: @"", self.bundleId ?: @"",
          self.displayName ?: @"", self.isActive ? 1 : 0,
          self.lastReason ?: @"",
          (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
  [body writeToFile:ZiYanVarFile(@".ziyan_agent_session")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  [body writeToFile:ZiYanVarFile(@".ziyan_agent_mode")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

- (void)transitTo:(AgentUIState)next reason:(NSString *)reason {
  AgentUIState prev = self.uiState;
  if (prev == AgentUICompleted && next != AgentUIWaitingLock &&
      next != AgentUICancelled && next != AgentUIIdle) {
    return;
  }
  self.uiState = next;
  self.lastReason = reason ?: @"";
  [self appendTransitFrom:prev to:next reason:reason];
  [self writeSession];
  [self writeSessionProbe];
}

- (void)clearTemps {
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *n in @[
         @".ziyan_agent_stop", @".ziyan_agent_learn_active",
         @".ziyan_agent_learn_inbox", @".ziyan_agent_learn_bridge.jsonl",
         @".ziyan_agent_learn_reject", @".ziyan_agent_learn_source"
       ]) {
    [fm removeItemAtPath:ZiYanVarFile(n) error:nil];
  }
}

- (void)stopPoller {
  self.polling = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(pollTick)
                                             object:nil];
  [self endBgTask];
}

- (void)startPoller {
  if (self.polling) {
    return;
  }
  self.polling = YES;
  [self beginBgTask];
  [self schedulePoll];
}

- (void)schedulePoll {
  if (!self.polling) {
    return;
  }
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(pollTick)
                                             object:nil];
  [self performSelector:@selector(pollTick) withObject:nil afterDelay:0.5];
}

- (NSString *)frontBid {
  return [[NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                                    encoding:NSUTF8StringEncoding
                                       error:nil]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]]
             ?: @"";
}

+ (BOOL)isLockableBid:(NSString *)bid {
  if (bid.length == 0 || [bid hasPrefix:@"com.ziyan."]) {
    return NO;
  }
  if ([bid isEqualToString:@"com.apple.springboard"] ||
      [bid isEqualToString:@"com.apple.Preferences"] ||
      [bid hasPrefix:@"com.apple.mobilephone"] ||
      [bid isEqualToString:@"com.apple.MobileSMS"] ||
      [bid isEqualToString:@"com.apple.mobileslideshow"] ||
      [bid isEqualToString:@"com.apple.MobileSafari"] ||
      [bid isEqualToString:@"com.apple.AppStore"]) {
    return NO;
  }
  return YES;
}

+ (NSString *)displayNameForBid:(NSString *)bid {
  for (ZiYanAppPick *p in [ZiYanAppSelector enumerateUserApps]) {
    if ([p.bundleId isEqualToString:bid]) {
      return p.displayName ?: bid;
    }
  }
  return bid;
}

- (void)recoverStaleSession {
  [AgentVersionStore quarantineSimArtifacts];
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_agent_session")
                                encoding:NSUTF8StringEncoding
                                   error:nil]
          ?: @"";
  if ([raw containsString:@"state=ITERATING"] ||
      [raw containsString:@"state=EXPLORING"] ||
      [raw containsString:@"state=GENERATING"] ||
      [raw containsString:@"state=LEARNING"] ||
      [raw containsString:@"state=WAITING_LOCK"] ||
      [raw containsString:@"active=1"]) {
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
      if ([line hasPrefix:@"session_id="]) {
        self.sessionId = [line substringFromIndex:11];
      }
      if ([line hasPrefix:@"mode="]) {
        self.mode = [line substringFromIndex:5];
      }
      if ([line hasPrefix:@"bundle_id="]) {
        self.bundleId = [line substringFromIndex:10];
      }
      if ([line hasPrefix:@"display_name="]) {
        self.displayName = [line substringFromIndex:13];
      }
    }
    [[AgentAutonomousEngine shared] cancel];
    [self stopPoller];
    [self clearTemps];
    self.uiState = AgentUICompleted;
    self.lastReason = @"recover_stale";
    [self writeSession];
  }
}

- (void)lockToBid:(NSString *)bid name:(NSString *)name {
  self.bundleId = bid;
  self.displayName = name.length ? name : [[self class] displayNameForBid:bid];
  NSString *body = [NSString
      stringWithFormat:
          @"profile_id=user_app\ndisplay_name=%@\ngame_name=%@\nbundle_id=%@\n"
          @"selected_ts=%lld\nsource=learn_lock\n",
          self.displayName, self.displayName, bid,
          (long long)[[NSDate date] timeIntervalSince1970]];
  [body writeToFile:ZiYanVarFile(@".ziyan_agent_current_profile")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  NSString *flag = [NSString
      stringWithFormat:@"1\nbundle_id=%@\nsession_id=%@\n", bid,
                       self.sessionId ?: @""];
  [flag writeToFile:ZiYanVarFile(@".ziyan_agent_learn_active")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  [[AgentLearningRecorder shared] setLockedBid:bid sessionId:self.sessionId];
  [self transitTo:AgentUILearning reason:@"lock_target"];
}

- (void)consumeActiveCmd {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *paths = @[
    ZiYanVarFile(@".ziyan_ui_cmd"),
    @"/private/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_ui_cmd",
  ];
  NSString *path = nil;
  for (NSString *p in paths) {
    if ([fm fileExistsAtPath:p]) {
      path = p;
      break;
    }
  }
  if (!path) {
    return;
  }
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil]
                      ?: @"";
  NSString *line =
      [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
          firstObject]
          ?: @"";
  line = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (line.length == 0) {
    return;
  }
  NSArray *parts = [line componentsSeparatedByString:@"\t"];
  NSString *cmd = parts.firstObject ?: @"";
  BOOL mine = [cmd isEqualToString:@"learn_lock"] ||
              [cmd isEqualToString:@"learn_vol"];
  if (!mine) {
    return;
  }
  for (NSString *p in paths) {
    [@"\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:p error:nil];
  }
  if ([cmd isEqualToString:@"learn_lock"] && parts.count >= 3) {
    [self lockTestTarget:parts[1] name:parts[2]];
  } else if ([cmd isEqualToString:@"learn_vol"]) {
    [self handleVolumeUp];
  }
  [self writeSessionProbe];
}

- (void)pollTick {
  if (!self.polling) {
    return;
  }
  [self consumeActiveCmd];
  if ([[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_agent_stop")]) {
    [self handleVolumeUp];
    if (self.acceptsVolumeStop) {
      [self schedulePoll];
    }
    return;
  }
  if (self.uiState == AgentUIWaitingLock) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 开始学习会最小化 ZiYan：前 1.6s 不锁，避免把过渡前台或即将失去的 App 锁死。
    if (self.waitingSince > 1 && (now - self.waitingSince) < 1.6) {
      self.pendingLockHits = 0;
      self.pendingLockBid = @"";
    } else {
      NSString *front = [self frontBid];
      if ([[self class] isLockableBid:front]) {
        if ([front isEqualToString:self.pendingLockBid]) {
          self.pendingLockHits += 1;
        } else {
          self.pendingLockBid = front;
          self.pendingLockHits = 1;
        }
        if (self.pendingLockHits >= 2) {
          [self lockToBid:front name:[[self class] displayNameForBid:front]];
        }
      } else {
        self.pendingLockHits = 0;
        self.pendingLockBid = @"";
      }
    }
  } else if (self.uiState == AgentUILearning) {
    [[AgentLearningRecorder shared] consumeBridge];
    if ([AgentLearningRecorder shared].pausedSafe) {
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_agent_learn_active")
                     error:nil];
      [self transitTo:AgentUIPausedSafe
               reason:[AgentLearningRecorder shared].pauseReason];
    }
  } else if (self.uiState == AgentUIPausedSafe) {
    [[AgentLearningRecorder shared] consumeBridge];
  }
  [self writeSessionProbe];
  [self schedulePoll];
}

- (void)cancelIdle {
  [self transitTo:AgentUICancelled reason:@"user_cancel"];
  self.sessionId = @"";
  self.mode = @"";
  [self stopPoller];
  [self clearTemps];
  [self writeSession];
}

- (BOOL)beginLearnArmed {
  if (self.isActive) {
    return NO;
  }
  self.sessionId = [NSString
      stringWithFormat:@"ags_%lld",
                       (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
  self.mode = @"learn";
  self.bundleId = @"";
  self.displayName = @"";
  self.waitingSince = [[NSDate date] timeIntervalSince1970];
  self.pendingLockHits = 0;
  self.pendingLockBid = @"";
  [[AgentLearningRecorder shared] reset];
  [self clearTemps];
  [self transitTo:AgentUIWaitingLock reason:@"learn_start"];
  [self startPoller];
  ZiYanRequestAppMinimizeAfterScriptStart(@"learn", self.sessionId);
  return YES;
}

- (void)cancelWaitingLock {
  [self transitTo:AgentUICancelled reason:@"volume_waiting_lock"];
  self.sessionId = @"";
  self.mode = @"";
  [self stopPoller];
  [self clearTemps];
  [[AgentLearningRecorder shared] reset];
  [self writeSession];
}

- (void)finishLearnGenerate {
  [self transitTo:AgentUIGenerating reason:@"volume_or_stop"];
  [[AgentLearningRecorder shared] consumeBridge];
  [[AgentLearningRecorder shared] finalizePending];
  [AgentLearningCompiler compileLearnSession:self.sessionId
                                        name:self.displayName.length
                                                 ? self.displayName
                                                 : @"YouXi"
                                         bid:self.bundleId ?: @""
                                      events:[AgentLearningRecorder shared].events];
  [self transitTo:AgentUICompleted reason:@"learn_generate_done"];
  [self stopPoller];
  [self clearTemps];
  [self refreshScriptList];
}

- (void)convergeFrozenMode:(NSString *)why {
  [[AgentAutonomousEngine shared] cancel];
  [self transitTo:AgentUICompleted reason:why];
  [self stopPoller];
  [self clearTemps];
}

- (void)handleVolumeUp {
  if (self.uiState == AgentUIWaitingLock) {
    [self cancelWaitingLock];
    return;
  }
  if (self.uiState == AgentUILearning || self.uiState == AgentUIPausedSafe) {
    [self finishLearnGenerate];
    return;
  }
  if (self.uiState == AgentUIExploring || self.uiState == AgentUIIterating) {
    [self convergeFrozenMode:@"p3p4_frozen_stop"];
    return;
  }
}

- (void)lockTestTarget:(NSString *)bid name:(NSString *)name {
  if (self.uiState != AgentUIWaitingLock) {
    return;
  }
  if (![[self class] isLockableBid:bid]) {
    return;
  }
  [self lockToBid:bid name:name];
}

- (void)writeSessionProbe {
  NSDictionary *info = @{
    @"ui_state" : [self uiStateText],
    @"state" : [self stateCode:self.uiState],
    @"session_id" : self.sessionId ?: @"",
    @"mode" : self.mode ?: @"",
    @"bundle_id" : self.bundleId ?: @"",
    @"display_name" : self.displayName ?: @"",
    @"active" : @(self.isActive),
    @"events" : @([AgentLearningRecorder shared].count),
    @"paused_safe" : @([AgentLearningRecorder shared].pausedSafe),
    @"reason" : self.lastReason ?: @"",
  };
  NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [d writeToFile:ZiYanVarFile(@".ziyan_ui_agent_session.json") atomically:YES];
}

- (void)refreshScriptList {
  UIWindow *win = nil;
  for (UIWindow *w in UIApplication.sharedApplication.windows) {
    if (w.isKeyWindow) {
      win = w;
      break;
    }
  }
  if (!win) {
    win = UIApplication.sharedApplication.windows.firstObject;
  }
  UIViewController *root = win.rootViewController;
  if ([root isKindOfClass:[UINavigationController class]]) {
    UIViewController *first =
        ((UINavigationController *)root).viewControllers.firstObject;
    if ([first isKindOfClass:[ZiYanHomeViewController class]]) {
      [(ZiYanHomeViewController *)first reloadScripts];
    }
  }
}

@end
