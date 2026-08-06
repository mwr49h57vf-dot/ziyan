#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SpringBoard：截屏取色/找色；backboardd：HID 触控注入。
/// 与 Lua 通过 /usr/lib/ziyan/var/.ziyan_* 文件 IPC 通信。
@interface ZiYanScreenBridge : NSObject
+ (instancetype)shared;
- (void)startInSpringBoard;
- (void)startInBackboardd;
/// 8-145：统一调度器接管后取消自有 0.06s timer（仅 SpringBoard）
- (void)suspendOwnTimer;
/// 8-145：由 UnifiedDispatcher 触发；仍投递到 screen.poll 串行队列（防找色死锁）
- (void)dispatchPoll;
/// 释放截屏缓存，降低 SpringBoard jetsam 压力（回桌面时调用）
- (void)clearCachedPixels;
/// 强制清像素+shm（高 RSS 修剪）；keep 开时调用方应跳过
- (void)clearCachedPixelsForce;
- (BOOL)isKeepScreenOn;
/// 松开可能卡住的合成触控（脚本 tap 未 up / 菜单抢 key 后主屏无法滑动）
- (void)releaseStuckTouches;
/// 8-161-63b：映射丢失时仍强制抬起手指 1..5（防 digitizer 粘滞导致无法滑动）
- (void)forceLiftAllFingers;
@end

NS_ASSUME_NONNULL_END
