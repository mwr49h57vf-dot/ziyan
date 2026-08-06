#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// T6：App↔daemon shm/文件桥（App 沙盒优先写 Media + ControlShm toast）
@interface ZiYanAppBridgeShm : NSObject
+ (instancetype)shared;
- (void)registerApp;
- (void)sendVolumeKey:(BOOL)isUp;
- (void)sendToast:(NSString *)text duration:(NSTimeInterval)ms;
- (nullable NSDictionary *)pollDaemonCommand;
- (BOOL)isDaemonAlive;
@end

NS_ASSUME_NONNULL_END
