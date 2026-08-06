#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// T5：SB 重启统计镜像（HUD 仍由 SB Toast / Dispatcher 展示）
@interface ZiYanSbRestartStatsDaemon : NSObject
+ (void)start;
+ (void)pollOnce;
@end

NS_ASSUME_NONNULL_END
