#import "ZiYanMinimalBridge.h"
#import "ZiYanControlShm.h"
#import "ZiYanIconShield.h"
#import "ZiYanPaths.h"
#import "ZiYanToastBridge.h"
#import "ZiYanUnifiedDispatcher.h"

/*
  T5：daemon→SB 最小执行桥
  - 优先 ControlShm toast_cmd（含 __ICON_HIDE__/__ICON_RESTORE__）
  - 文件 .ziyan_daemon_* 作 fallback（兼容期）
*/

@implementation ZiYanMinimalBridge

+ (void)start {
  if ([ZiYanUnifiedDispatcher isActive]) {
    [[ZiYanUnifiedDispatcher shared]
        registerToastBridgeCallback:^{
          [ZiYanMinimalBridge pollOnce];
        }];
  } else {
    // 8-161-46：thin 未启 UnifiedDispatcher 时自管轮询（图标 restore cmd）
    static dispatch_source_t sThinTimer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      dispatch_queue_t q =
          dispatch_queue_create("com.ziyan.minimal.thin", DISPATCH_QUEUE_SERIAL);
      sThinTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
      dispatch_source_set_timer(sThinTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                (uint64_t)(0.25 * NSEC_PER_SEC),
                                (uint64_t)(0.05 * NSEC_PER_SEC));
      dispatch_source_set_event_handler(sThinTimer, ^{
        [ZiYanMinimalBridge pollOnce];
      });
      dispatch_resume(sThinTimer);
    });
  }
  ZiYanWriteVarText(@".ziyan_minimal_bridge",
                    [NSString stringWithFormat:@"ts=%.0f active=1 shm=1\n",
                                               [[NSDate date]
                                                   timeIntervalSince1970]]);
}

+ (void)handleIconToken:(NSString *)token {
  if ([token isEqualToString:@"hide"] ||
      [token isEqualToString:@"__ICON_HIDE__"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [ZiYanIconShield executeHideFromDaemon];
    });
  } else if ([token isEqualToString:@"restore"] ||
             [token isEqualToString:@"__ICON_RESTORE__"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [ZiYanIconShield executeRestoreFromDaemon];
    });
  }
}

+ (void)pollOnce {
  // 1) shm toast（daemon 决策层写入）
  NSString *shmText = nil;
  int shmMs = 0;
  if (ZiYanControlShmTakeToast(&shmText, &shmMs) && shmText.length > 0) {
    if ([shmText hasPrefix:@"__ICON_"]) {
      [self handleIconToken:shmText];
    } else if (!ZiYanZeroSbInject()) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [[ZiYanToastBridge shared] showToast:shmText
                                   duration:MAX(0.4, shmMs / 1000.0)];
      });
    }
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *iconCmd = ZiYanVarFile(@".ziyan_daemon_icon_cmd");
  if ([fm fileExistsAtPath:iconCmd]) {
    NSString *raw = [NSString stringWithContentsOfFile:iconCmd
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    [fm removeItemAtPath:iconCmd error:nil];
    NSString *cmd = [[raw componentsSeparatedByCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         firstObject] ?:
                    @"";
    [self handleIconToken:cmd];
  }
  NSString *toastCmd = ZiYanVarFile(@".ziyan_daemon_toast_cmd");
  if ([fm fileExistsAtPath:toastCmd]) {
    NSString *raw = [NSString stringWithContentsOfFile:toastCmd
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    [fm removeItemAtPath:toastCmd error:nil];
    if (raw.length > 0 && !ZiYanZeroSbInject()) {
      NSArray *parts = [raw componentsSeparatedByString:@"\n"];
      NSString *text = parts.count > 0 ? parts[0] : raw;
      NSTimeInterval ms = parts.count > 1 ? [parts[1] doubleValue] : 1500;
      dispatch_async(dispatch_get_main_queue(), ^{
        [[ZiYanToastBridge shared] showToast:text
                                   duration:MAX(0.4, ms / 1000.0)];
      });
    }
  }
}

@end
