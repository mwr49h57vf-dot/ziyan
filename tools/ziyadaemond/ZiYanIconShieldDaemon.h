#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// T5：图标决策在 daemon；执行仍由 SB MinimalBridge / IconShield
@interface ZiYanIconShieldDaemon : NSObject
+ (void)start;
+ (void)pollOnce;
@end

NS_ASSUME_NONNULL_END
