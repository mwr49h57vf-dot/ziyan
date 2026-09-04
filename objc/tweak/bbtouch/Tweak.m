#import <Foundation/Foundation.h>
#import "ZiYanTouchBridge.h"
#import <unistd.h>

/*
 * 8-161-62：临摹触动 TSEventTweak（仅注入 backboardd）
 * - 轮询 .ziyan_touch_req → IOHID（见 ZiYanTouchBridge）
 * - 游戏内 AppTouch 保活时主动让路（.ziyan_app_alive）
 * - 禁止截屏 / UIKit / 音量 Hook，避免拖死系统触控
 * 注：用 constructor 而非 %ctor，避免本目标未走 Logos 预处理。
 */

static int ZiYanBBTouchEnabled(void) {
  return access("/usr/lib/ziyan/var/.ziyan_bbtouch_enable", F_OK) == 0 ||
         access("/var/jb/usr/lib/ziyan/var/.ziyan_bbtouch_enable", F_OK) == 0;
}

__attribute__((constructor)) static void ZiYanBBTouchInit(void) {
  // backboardd 冷启动默认零副作用：未显式授权时不加载 IOKit、不建 timer、不轮询。
  if (!ZiYanBBTouchEnabled()) {
    return;
  }
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
          if (!ZiYanBBTouchEnabled()) {
            return;
          }
          [[ZiYanTouchBridge shared] startInBackboardd];
          NSLog(@"[ZiYanBBTouch] enabled in backboardd");
        }
      });
}
