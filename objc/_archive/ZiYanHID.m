#import "ZiYanTouchBridge.h"
#import <Foundation/Foundation.h>

/*
 * 轻量 backboardd 触控桥：只投递 HID，不做截屏/音量/Toast。
 * 与 ZiYanVol（SpringBoard）分离，避免把 UIKit/引擎拖进 backboardd。
 */

__attribute__((constructor)) static void ZiYanHIDInit(void) {
  @autoreleasepool {
    NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
    if (![proc isEqualToString:@"backboardd"]) {
      return;
    }
    // 稍晚启动，等 HID 系统就绪
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          [[ZiYanTouchBridge shared] startInBackboardd];
          NSLog(@"[ZiYanHID] touch bridge started in backboardd");
        });
  }
}
