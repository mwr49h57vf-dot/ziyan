#import <Foundation/Foundation.h>
#import "ZiYanAppSelector.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZiYanDumpManager : NSObject
/// 采集到 ZYCV/<AppName>/ + 侧车分析报告；返回 ZYCV 目录
+ (nullable NSString *)dumpAndAnalyze:(ZiYanAppPick *)app
                                error:(NSString *_Nullable *_Nullable)errOut;
@end

NS_ASSUME_NONNULL_END
