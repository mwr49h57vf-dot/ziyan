#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ZiYAN_DispatchCallback)(void);

/*
  8-150 / 终稿 P0-5：统一 0.1s tick
  业务模块 register 回调；禁止回调内 >50ms 阻塞
  崩溃安全：单回调 @try/@catch
*/

@interface ZiYanUnifiedDispatcher : NSObject

+ (instancetype)shared;
+ (void)start;
+ (void)stop;
+ (BOOL)isActive;
- (uint64_t)currentTick;

- (void)registerScreenBridgeCallback:(ZiYAN_DispatchCallback)cb;
- (void)registerToastBridgeCallback:(ZiYAN_DispatchCallback)cb;
- (void)registerVolTrigPollerCallback:(ZiYAN_DispatchCallback)cb;
- (void)registerIconShieldCallback:(ZiYAN_DispatchCallback)cb;
- (void)registerWatchdogCallback:(ZiYAN_DispatchCallback)cb;
- (void)registerRestartHUDCallback:(ZiYAN_DispatchCallback)cb;

@end

/// VolTrig 供调度器调用（Tweak.m 实现）
#ifdef __cplusplus
extern "C" {
#endif
void ZiYanVolTrigPollOnce(void);
void ZiYanVolTrigSuspendOwnTimer(void);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
