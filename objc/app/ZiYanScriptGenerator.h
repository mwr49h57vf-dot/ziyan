#import <Foundation/Foundation.h>
#import "ZiYanAppSelector.h"

NS_ASSUME_NONNULL_BEGIN

/// R8.4.11：本地 Agent 进度回调（P/V/K/G 阶段 Toast）；禁止收费云 API
typedef void (^ZiYanScriptGenProgress)(NSString *stage);

@interface ZiYanScriptGenerator : NSObject
/// 侧车生成业务 Lua；成功返回落盘绝对路径（内部走 P→V→K→G）
+ (nullable NSString *)generateForApp:(ZiYanAppPick *)app
                          resProfile:(NSString *)resProfile
                               error:(NSString *_Nullable *_Nullable)errOut;

/// 同上 + 进度回调（底栏「自动生成脚本」用）
+ (nullable NSString *)generateForApp:(ZiYanAppPick *)app
                          resProfile:(NSString *)resProfile
                            progress:(nullable ZiYanScriptGenProgress)progress
                               error:(NSString *_Nullable *_Nullable)errOut;
@end

NS_ASSUME_NONNULL_END
