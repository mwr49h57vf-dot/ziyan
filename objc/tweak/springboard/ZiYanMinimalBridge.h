#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// T5：SB 最小桥 — 消费 daemon 指令（图标/toast），执行层仍在本进程
@interface ZiYanMinimalBridge : NSObject
+ (void)start;
+ (void)pollOnce;
@end

NS_ASSUME_NONNULL_END
