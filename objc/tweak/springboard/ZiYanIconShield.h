#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SpringBoard 侧：隐藏桌面越狱相关图标（保留 com.ziyan.ziyan）。
/// 不注入指纹 Hook；冷启 / 关程序 / App 进程消失后自动恢复。
@interface ZiYanIconShield : NSObject

+ (void)startInSpringBoard;
/// T5：daemon_v2 时仅装 Hook + 执行层，不创建 5s 决策定时器
+ (void)startHooksOnly;
/// 8-145：统一调度器接管后取消自有 5s timer
+ (void)suspendOwnTimer;
/// 8-145：单次边沿轮询（hide/restore）
+ (void)pollOnce;
/// App 前台触发 / 轮询命中 → 隐藏
+ (void)hideJailbreakIconsIfNeeded;
/// 关闭程序 / 冷启 / App 死掉 → 恢复
+ (void)restoreJailbreakIcons;
+ (BOOL)isHiding;

/// T5：daemon → MinimalBridge 执行入口（硬锁图标仍在 SB）
+ (void)executeHideFromDaemon;
+ (void)executeRestoreFromDaemon;

@end

NS_ASSUME_NONNULL_END
