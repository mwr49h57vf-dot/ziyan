#import "ZiYanUnifiedDispatcher.h"
#import "ZiYanBootRecovery.h"
#import "ZiYanControlShm.h"
#import "ZiYanHIDOptimizer.h"
#import "ZiYanIconShield.h"
#import "ZiYanPaths.h"
#import "ZiYanSbRestartStats.h"
#import "ZiYanScreenBridge.h"
#import "ZiYanToastBridge.h"
#import "ZiyanProcessWatchdog.h"
#import <UIKit/UIKit.h>
#import <mach/mach.h>

/*
  终稿 §7.2 / 8-150：单 0.1s tick + 可注册回调
  tick%1 Screen / %3 Toast / %5 Vol / %50 Icon+Watchdog / %300 HUD
*/

@interface ZiYanUnifiedDispatcher ()
@property(nonatomic, strong) NSMutableArray<ZiYAN_DispatchCallback> *screenCbs;
@property(nonatomic, strong) NSMutableArray<ZiYAN_DispatchCallback> *toastCbs;
@property(nonatomic, strong) NSMutableArray<ZiYAN_DispatchCallback> *volCbs;
@property(nonatomic, strong) NSMutableArray<ZiYAN_DispatchCallback> *iconCbs;
@property(nonatomic, strong) NSMutableArray<ZiYAN_DispatchCallback> *watchCbs;
@property(nonatomic, strong) NSMutableArray<ZiYAN_DispatchCallback> *hudCbs;
@end

@implementation ZiYanUnifiedDispatcher {
  dispatch_source_t _timer;
  dispatch_queue_t _queue;
  BOOL _active;
  uint64_t _tick;
}

+ (instancetype)shared {
  static ZiYanUnifiedDispatcher *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
  });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) {
    _screenCbs = [NSMutableArray array];
    _toastCbs = [NSMutableArray array];
    _volCbs = [NSMutableArray array];
    _iconCbs = [NSMutableArray array];
    _watchCbs = [NSMutableArray array];
    _hudCbs = [NSMutableArray array];
    _queue = dispatch_queue_create("com.ziyan.unified.dispatch",
                                   DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

+ (BOOL)isActive {
  ZiYanUnifiedDispatcher *s = [self shared];
  return s->_active;
}

- (uint64_t)currentTick {
  return _tick;
}

- (void)registerScreenBridgeCallback:(ZiYAN_DispatchCallback)cb {
  if (cb)
    [self.screenCbs addObject:[cb copy]];
}
- (void)registerToastBridgeCallback:(ZiYAN_DispatchCallback)cb {
  if (cb)
    [self.toastCbs addObject:[cb copy]];
}
- (void)registerVolTrigPollerCallback:(ZiYAN_DispatchCallback)cb {
  if (cb)
    [self.volCbs addObject:[cb copy]];
}
- (void)registerIconShieldCallback:(ZiYAN_DispatchCallback)cb {
  if (cb)
    [self.iconCbs addObject:[cb copy]];
}
- (void)registerWatchdogCallback:(ZiYAN_DispatchCallback)cb {
  if (cb)
    [self.watchCbs addObject:[cb copy]];
}
- (void)registerRestartHUDCallback:(ZiYAN_DispatchCallback)cb {
  if (cb)
    [self.hudCbs addObject:[cb copy]];
}

static void runCbs(NSArray<ZiYAN_DispatchCallback> *arr) {
  for (ZiYAN_DispatchCallback cb in arr) {
    @try {
      cb();
    } @catch (NSException *ex) {
      [ZiYanBootRecovery appendLifecycle:@"unified_cb_ex"
                                  detail:ex.reason ?: @"?"];
    }
  }
}

+ (void)stop {
  [[self shared] stopInternal];
}

- (void)stopInternal {
  _active = NO;
  if (_timer) {
    dispatch_source_cancel(_timer);
    _timer = nil;
  }
  [ZiYanBootRecovery appendLifecycle:@"unified_dispatch_stop" detail:@""];
}

+ (void)start {
  [[self shared] startInternal];
}

- (void)startInternal {
  if (_active) {
    return;
  }
  _active = YES;
  _tick = 0;

  // 默认注册（模块亦可再 register）
  if (self.screenCbs.count == 0) {
    [self registerScreenBridgeCallback:^{
      [[ZiYanScreenBridge shared] dispatchPoll];
    }];
  }
  // T6：零 SB 注入时 Toast 由 App Overlay 消费，跳过 SB Toast 轮询
  BOOL zeroSb = ZiYanZeroSbInject();
  // T5：daemon_v2 在时 Icon/Watchdog/HUD 决策在 ziyadaemond，SB 跳过双轮询
  BOOL daemonV2 = ZiYanDaemonV2Active();
  if (!zeroSb && self.toastCbs.count == 0) {
    [self registerToastBridgeCallback:^{
      [[ZiYanToastBridge shared] pollCommand];
    }];
  }
  if (self.volCbs.count == 0) {
    [self registerVolTrigPollerCallback:^{
      ZiYanVolTrigPollOnce();
    }];
  }
  if (!daemonV2 && self.iconCbs.count == 0) {
    [self registerIconShieldCallback:^{
      [ZiYanIconShield pollOnce];
    }];
  }
  if (!daemonV2 && self.watchCbs.count == 0) {
    [self registerWatchdogCallback:^{
      dispatch_async(dispatch_get_main_queue(), ^{
        [ZiyanProcessWatchdog checkAllProcesses];
      });
    }];
  }
  if (!daemonV2 && self.hudCbs.count == 0) {
    [self registerRestartHUDCallback:^{
      dispatch_async(dispatch_get_main_queue(), ^{
        [ZiYanSbRestartStats refreshHudText];
      });
    }];
  }

  [[ZiYanScreenBridge shared] suspendOwnTimer];
  if (!zeroSb) {
    [[ZiYanToastBridge shared] suspendOwnTimer];
  }
  ZiYanVolTrigSuspendOwnTimer();
  [ZiYanIconShield suspendOwnTimer];
  [ZiyanProcessWatchdog adoptExternalSchedule];
  [ZiYanSbRestartStats adoptExternalSchedule];
  [[ZiYanHIDOptimizer shared] prewarmTemplates];

  ZiYanControlShmEnsure();
  ZiYanControlShmSyncFromFiles();
  ZiYanControlShmWriteHeartbeat(@"sb");

  _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(0.1 * NSEC_PER_SEC),
                            (uint64_t)(0.02 * NSEC_PER_SEC));
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_timer, ^{
    __strong typeof(weakSelf) self = weakSelf;
    if (!self) {
      return;
    }
    self->_tick++;
    uint64_t t = self->_tick;
    @autoreleasepool {
      runCbs(self.screenCbs);
      if (t % 3 == 0) {
        runCbs(self.toastCbs);
      }
      if (t % 5 == 0) {
        runCbs(self.volCbs);
      }
      if (t % 50 == 0) {
        runCbs(self.iconCbs);
        runCbs(self.watchCbs);
        ZiYanControlShmSyncFromFiles();
        ZiYanControlShmWriteHeartbeat(@"sb");
      }
      if (t % 300 == 0) {
        runCbs(self.hudCbs);
        // 设备实测 P0-3：RSS>150MB 且非 keep → 强制清缓存（降 jetsam）
        // 内存风险：只清像素缓冲，不碰找色公式
        @try {
          task_vm_info_data_t info;
          mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
          if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info,
                        &count) == KERN_SUCCESS) {
            uint64_t rssMB = info.phys_footprint / (1024ull * 1024ull);
            if (rssMB == 0) {
              rssMB = info.resident_size / (1024ull * 1024ull);
            }
            ZiYanWriteVarText(
                @".ziyan_sb_rss",
                [NSString stringWithFormat:@"ts=%.0f rss_mb=%llu\n",
                                           [[NSDate date] timeIntervalSince1970],
                                           (unsigned long long)rssMB]);
            if (rssMB > 150) {
              ZiYanScreenBridge *br = [ZiYanScreenBridge shared];
              if (br && ![br isKeepScreenOn]) {
                [br clearCachedPixelsForce];
                ZiYanWriteVarText(@".ziyan_sb_rss_trim",
                                  [NSString stringWithFormat:@"ts=%.0f rss_mb=%llu\n",
                                                             [[NSDate date]
                                                                 timeIntervalSince1970],
                                                             (unsigned long long)rssMB]);
              }
            }
          }
        } @catch (__unused NSException *ex) {
        }
      }
      // 每 1s 心跳
      if (t % 10 == 0) {
        ZiYanWriteVarText(
            @".ziyan_dispatcher_alive",
            [NSString stringWithFormat:@"ts=%.0f tick=%llu active=1\n",
                                       [[NSDate date] timeIntervalSince1970],
                                       (unsigned long long)t]);
        ZiYanWriteVarText(
            @".ziyan_unified_dispatch",
            [NSString stringWithFormat:@"ts=%.0f active=1 tick=0.1 n=%llu\n",
                                       [[NSDate date] timeIntervalSince1970],
                                       (unsigned long long)t]);
      }
    }
  });
  dispatch_resume(_timer);
  [ZiYanBootRecovery appendLifecycle:@"unified_dispatcher_start"
                              detail:@"tick=0.1s"];
}

@end
