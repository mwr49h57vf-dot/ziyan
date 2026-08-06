#import "ZiYanAppKeepAlive.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

// BackBoardServices 私有：防挂起（JB platform-application 下可用；不链 SB）
enum {
  kZiYanBKSPreventSuspend = 1 << 0,
  kZiYanBKSPreventThrottleCPU = 1 << 1,
  kZiYanBKSPreventThrottleUI = 1 << 2,
  kZiYanBKSWantsFGPriority = 1 << 3,
};
enum {
  kZiYanBKSReasonAudio = 1,
  kZiYanBKSReasonFinishTask = 4,
  kZiYanBKSReasonBackgroundUI = 7,
};

@interface ZiYanAppKeepAlive ()
@property(nonatomic, strong, nullable) id sessionAssertion;
@property(nonatomic, strong, nullable) id menuAssertion;
@property(nonatomic, assign) BOOL sessionActive;
@property(nonatomic, assign) BOOL overlayOnlyWake;
@property(nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@end

@implementation ZiYanAppKeepAlive

+ (instancetype)shared {
  static ZiYanAppKeepAlive *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
    s.bgTask = UIBackgroundTaskInvalid;
  });
  return s;
}

- (id)acquireBKSWithFlags:(unsigned int)flags
                   reason:(unsigned int)reason
                     name:(NSString *)name {
  Class cls = NSClassFromString(@"BKSProcessAssertion");
  if (!cls) {
    return nil;
  }
  // - initWithPID:flags:reason:name:withHandler:
  SEL sel = NSSelectorFromString(
      @"initWithPID:flags:reason:name:withHandler:");
  if (![cls instancesRespondToSelector:sel]) {
    return nil;
  }
  id raw = [cls alloc];
  if (!raw) {
    return nil;
  }
  void (^handler)(BOOL) = ^(BOOL ok) {
    if (!ok) {
      NSLog(@"[ZiYanKeepAlive] assertion invalid name=%@", name);
    }
  };
  id (*msg)(id, SEL, int, unsigned int, unsigned int, id, id) =
      (id(*)(id, SEL, int, unsigned int, unsigned int, id, id))objc_msgSend;
  id assertion = msg(raw, sel, (int)getpid(), flags, reason, name, handler);
  return assertion;
}

- (void)invalidateAssertion:(id)assertion {
  if (!assertion) {
    return;
  }
  SEL inv = NSSelectorFromString(@"invalidate");
  if ([assertion respondsToSelector:inv]) {
    ((void (*)(id, SEL))objc_msgSend)(assertion, inv);
  }
}

- (void)renewBackgroundTask {
  UIApplication *app = UIApplication.sharedApplication;
  if (self.bgTask != UIBackgroundTaskInvalid) {
    [app endBackgroundTask:self.bgTask];
    self.bgTask = UIBackgroundTaskInvalid;
  }
  __weak typeof(self) weakSelf = self;
  self.bgTask = [app beginBackgroundTaskWithName:@"ziyan.keepalive"
                               expirationHandler:^{
                                 __strong typeof(weakSelf) self = weakSelf;
                                 if (!self) {
                                   return;
                                 }
                                 // 到期立刻续：配合 audio 保活，避免菜单随挂起消失
                                 if (self.sessionActive) {
                                   [self renewBackgroundTask];
                                 } else if (self.bgTask !=
                                            UIBackgroundTaskInvalid) {
                                   [app endBackgroundTask:self.bgTask];
                                   self.bgTask = UIBackgroundTaskInvalid;
                                 }
                               }];
}

- (void)startSession {
  if (self.sessionActive && self.sessionAssertion) {
    [self renewBackgroundTask];
    return;
  }
  self.sessionActive = YES;
  [self invalidateAssertion:self.sessionAssertion];
  unsigned int flags = kZiYanBKSPreventSuspend | kZiYanBKSPreventThrottleCPU |
                       kZiYanBKSPreventThrottleUI | kZiYanBKSWantsFGPriority;
  self.sessionAssertion =
      [self acquireBKSWithFlags:flags
                         reason:kZiYanBKSReasonBackgroundUI
                           name:@"ziyan.vol.session"];
  if (!self.sessionAssertion) {
    // 回退 FinishTask
    self.sessionAssertion =
        [self acquireBKSWithFlags:flags
                           reason:kZiYanBKSReasonFinishTask
                             name:@"ziyan.vol.session.ft"];
  }
  [self renewBackgroundTask];
  [UIApplication sharedApplication].idleTimerDisabled = YES;
  ZiYanWriteVarText(@".ziyan_app_keepalive", @"1\n");
  NSLog(@"[ZiYanKeepAlive] session start assert=%@",
        self.sessionAssertion ? @"ok" : @"nil");
}

- (void)closeSession {
  self.sessionActive = NO;
  [self menuDidClose];
  [self invalidateAssertion:self.sessionAssertion];
  self.sessionAssertion = nil;
  if (self.bgTask != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
    self.bgTask = UIBackgroundTaskInvalid;
  }
  [UIApplication sharedApplication].idleTimerDisabled = NO;
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_app_keepalive")
                 error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_vol_menu_sticky")
                 error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_menu_overlay_only")
                 error:nil];
  self.overlayOnlyWake = NO;
  NSLog(@"[ZiYanKeepAlive] session closed → volume keys restore");
}

- (void)menuDidOpen {
  [self startSession];
  [self invalidateAssertion:self.menuAssertion];
  unsigned int flags = kZiYanBKSPreventSuspend | kZiYanBKSPreventThrottleUI |
                       kZiYanBKSWantsFGPriority;
  self.menuAssertion =
      [self acquireBKSWithFlags:flags
                         reason:kZiYanBKSReasonBackgroundUI
                           name:@"ziyan.vol.menu"];
  ZiYanWriteVarText(@".ziyan_vol_menu_sticky", @"1\n");
}

- (void)menuDidClose {
  [self invalidateAssertion:self.menuAssertion];
  self.menuAssertion = nil;
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_vol_menu_sticky")
                 error:nil];
}

- (void)wakeRenderContextForOverlayOnly {
  // 进程已在后台：需要合成层才能让透明信息框出现在桌面之上；
  // 配合 Overlay 藏主窗 = 用户只见信息框，不见 App 列表（≠ 同步露主界面）
  UIApplicationState st = UIApplication.sharedApplication.applicationState;
  if (st == UIApplicationStateActive) {
    return;
  }
  self.overlayOnlyWake = YES;
  ZiYanWriteVarText(@".ziyan_menu_overlay_only", @"1\n");
  [self startSession];
  Class LS = NSClassFromString(@"LSApplicationWorkspace");
  if (!LS) {
    return;
  }
  SEL defSel = NSSelectorFromString(@"defaultWorkspace");
  SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
  if (![LS respondsToSelector:defSel]) {
    return;
  }
  id (*msg0)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
  id ws = msg0((id)LS, defSel);
  if (!ws || ![ws respondsToSelector:openSel]) {
    return;
  }
  BOOL (*msg1)(id, SEL, id) = (BOOL(*)(id, SEL, id))objc_msgSend;
  msg1(ws, openSel, @"com.ziyan.ziyan");
}

- (void)suspendAfterOverlayOnlyIfNeeded {
  if (!self.overlayOnlyWake) {
    return;
  }
  self.overlayOnlyWake = NO;
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_menu_overlay_only")
                 error:nil];
  UIApplication *app = UIApplication.sharedApplication;
  SEL sus = NSSelectorFromString(@"suspend");
  if ([app respondsToSelector:sus]) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          ((void (*)(id, SEL))objc_msgSend)(app, sus);
        });
  }
}

@end
