#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// T5：冷启清理 / 孤儿 lua 回收（不依赖 SB UI）
@interface ZiYanBootRecoveryDaemon : NSObject
+ (void)start;
+ (void)pollOnce;
@end

NS_ASSUME_NONNULL_END
