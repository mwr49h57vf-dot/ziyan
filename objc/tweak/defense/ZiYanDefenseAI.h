#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 本地启发式 + 可选 ONNX 插件位（权重需离线放入 models/，默认不联网下载）
@interface ZiYanDefenseAI : NSObject
+ (instancetype)shared;
- (void)startMonitoring;
- (void)stopMonitoring;
/// 模拟突破：写入证据并跑判定（验收用）
- (void)ingestBypassEvidence:(NSString *)evidence bundleId:(NSString *)bid;
/// 若分析中需延迟退出：返回 YES 表示调用方应等待
- (BOOL)shouldDeferExitWithToast;
- (float)lastConfidence;
@end

NS_ASSUME_NONNULL_END
