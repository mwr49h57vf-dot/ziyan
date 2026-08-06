#import <Foundation/Foundation.h>
#import "ZiYanTouchBridge.h"

/*
 * 8-161-62：临摹触动 TSEventTweak（仅注入 backboardd）
 * - 轮询 .ziyan_touch_req → IOHID（见 ZiYanTouchBridge）
 * - 游戏内 AppTouch 保活时主动让路（.ziyan_app_alive）
 * - 禁止截屏 / UIKit / 音量 Hook，避免拖死系统触控
 * 注：用 constructor 而非 %ctor，避免本目标未走 Logos 预处理。
 */

__attribute__((constructor)) static void ZiYanBBTouchInit(void) {
  @autoreleasepool {
    [[ZiYanTouchBridge shared] startInBackboardd];
    NSLog(@"[ZiYanBBTouch] started in backboardd (TSEvent-like HID bridge)");
  }
}
