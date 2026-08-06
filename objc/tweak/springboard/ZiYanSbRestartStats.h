#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 8-143：SB 重启 toast + 机上自统计 HUD
@interface ZiYanSbRestartStats : NSObject
+ (void)onSpringBoardBoot;
+ (void)showHudIfNeeded;
+ (void)refreshHudText;
/// 8-145：取消自有 30s HUD NSTimer，改由 UnifiedDispatcher 刷新
+ (void)adoptExternalSchedule;
@end

NS_ASSUME_NONNULL_END
