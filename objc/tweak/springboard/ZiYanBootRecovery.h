#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZiYanBootRecovery : NSObject
+ (void)onSpringBoardUp;
+ (BOOL)isJailbreakEnvironmentActive;
+ (BOOL)isRootlessScheme;
+ (void)appendLifecycle:(NSString *)event detail:(NSString *_Nullable)detail;
+ (void)killOrphanLuaProcesses;
+ (nullable NSDictionary *)readSnapshot;
+ (NSString *)snapshotPath;
+ (NSString *)tipPath;
@end

NS_ASSUME_NONNULL_END
